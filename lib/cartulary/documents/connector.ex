# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Documents.Connector do
  @moduledoc """
  Strategy behaviour for incremental external document sources.

  Adapters return raw observations only. Cursors advance only after every item
  in a page is durably versioned or tombstoned.
  """

  @type item :: %{
          required(:external_id) => String.t(),
          optional(:title) => String.t(),
          optional(:media_type) => String.t(),
          optional(:bytes) => binary(),
          optional(:source_uri) => String.t(),
          optional(:metadata) => map(),
          optional(:deleted?) => boolean(),
          optional(:occurred_at) => DateTime.t()
        }

  @type page :: %{
          required(:items) => [item()],
          required(:cursor) => map(),
          optional(:has_more?) => boolean()
        }

  @callback pull(Cartulary.Documents.ConnectorConfig.t(), map()) ::
              {:ok, page()} | {:error, term()}

  def adapter!(kind) when is_binary(kind) do
    adapters =
      :cartulary
      |> Application.fetch_env!(:documents)
      |> Keyword.fetch!(:connector_adapters)

    Map.get(adapters, kind) ||
      raise ArgumentError, "connector adapter is not configured for #{inspect(kind)}"
  end
end
