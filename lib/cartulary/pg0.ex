# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Pg0 do
  @moduledoc """
  Release-owned lifecycle manager for the pinned pg0 process.

  pg0 daemonises PostgreSQL itself. This process validates the data directory,
  handles a stale `postmaster.pid`, starts the named instance, and stops it
  during an orderly release shutdown.
  """

  use GenServer

  require Logger

  @startup_timeout_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop_database do
    GenServer.call(__MODULE__, :stop_database, 35_000)
  end

  @impl true
  def init(_opts) do
    config = pg0_config()
    prepare_data_dir!(config)
    start_or_attach!(config)
    {:ok, config}
  end

  @impl true
  def terminate(_reason, config) do
    stop_database(config)
  end

  @impl true
  def handle_call(:stop_database, _from, config) do
    {:reply, stop_database(config), config}
  end

  # Binary/name are fail-fast validated release configuration, never request input.
  # sobelow_skip ["CI.System"]
  defp stop_database(config) do
    {_output, status} =
      System.cmd(config[:binary], ["stop", "--name", config[:name], "--timeout", "30"],
        stderr_to_stdout: true
      )

    if status != 0 do
      Logger.warning("pg0 instance #{config[:name]} did not stop cleanly")
    end

    :ok
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 35_000,
      type: :worker
    }
  end

  defp pg0_config do
    :cartulary
    |> Application.fetch_env!(:database)
    |> Keyword.fetch!(:pg0)
  end

  # The absolute operator-configured root is validated before this child starts.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_data_dir!(config) do
    data_dir = config[:data_dir]
    parent = Path.dirname(data_dir)
    File.mkdir_p!(parent)

    if File.exists?(data_dir) and not File.dir?(data_dir) do
      raise "pg0 data path exists but is not a directory: #{data_dir}"
    end

    File.mkdir_p!(data_dir)
    writable_probe = Path.join(data_dir, ".cartulary-write-check")
    File.write!(writable_probe, "ok", [:binary])
    File.rm!(writable_probe)
    handle_postmaster_pid!(Path.join(data_dir, "postmaster.pid"))
  end

  # `path` is derived only from the validated pg0 data root.
  # sobelow_skip ["Traversal.FileModule"]
  defp handle_postmaster_pid!(path) do
    case File.read(path) do
      {:ok, contents} ->
        with [pid_line | _rest] <- String.split(contents, "\n"),
             {pid, ""} <- Integer.parse(String.trim(pid_line)) do
          if process_alive?(pid) do
            :ok
          else
            stale = path <> ".stale-" <> Integer.to_string(System.system_time(:second))
            File.rename!(path, stale)
            Logger.warning("moved stale pg0 postmaster pid to #{stale}")
          end
        else
          _other -> raise "invalid pg0 postmaster.pid at #{path}"
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise "cannot inspect pg0 postmaster.pid: #{inspect(reason)}"
    end
  end

  defp process_alive?(pid) when is_integer(pid) and pid > 0 do
    case :os.type() do
      {:win32, _name} ->
        {output, status} =
          System.cmd("tasklist", ["/FI", "PID eq #{pid}", "/NH"], stderr_to_stdout: true)

        status == 0 and String.contains?(output, Integer.to_string(pid))

      _unix ->
        case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
          {_output, 0} -> true
          {_output, _status} -> false
        end
    end
  end

  # Binary and every argument are validated release configuration, not request input.
  # sobelow_skip ["CI.System"]
  defp start_or_attach!(config) do
    pid_path = Path.join(config[:data_dir], "postmaster.pid")

    if File.exists?(pid_path) do
      Logger.info("attaching to release-owned pg0 instance #{config[:name]}")
    else
      ensure_port_available!(config[:port])

      args = [
        "start",
        "--name",
        config[:name],
        "--port",
        Integer.to_string(config[:port]),
        "--version",
        config[:postgres_version],
        "--data-dir",
        config[:data_dir],
        "--username",
        config[:username],
        "--password",
        config[:password],
        "--database",
        config[:database]
      ]

      {output, status} = System.cmd(config[:binary], args, stderr_to_stdout: true)

      if status != 0 do
        raise "pg0 failed to start: #{String.trim(output)}"
      end
    end

    wait_for_port!(config[:port], @startup_timeout_ms)
  end

  defp ensure_port_available!(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        raise "pg0 port #{port} is already in use; choose CARTULARY_PG0_PORT or use external mode"

      {:error, _reason} ->
        :ok
    end
  end

  defp wait_for_port!(_port, remaining) when remaining <= 0 do
    raise "pg0 did not become ready before the startup deadline"
  end

  defp wait_for_port!(port, remaining) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        wait_for_port!(port, remaining - 100)
    end
  end
end
