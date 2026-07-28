# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Portability do
  @moduledoc "Free-core F10 Account portability boundary."

  defdelegate export(actor, output_path), to: Cartulary.Portability.Archive
  defdelegate import(input_path), to: Cartulary.Portability.Archive
  defdelegate validate(input_path), to: Cartulary.Portability.Archive
end
