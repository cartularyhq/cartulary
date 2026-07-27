# SPDX-License-Identifier: Cartulary-Sustainable-Use-1.0

defmodule Cartulary.Memory.Domain do
  @moduledoc """
  Ash domain for the Cartulary POC memory resources.

  The first POC surface uses service functions over these tables, but the
  resources keep the codebase anchored to the Ash domain boundary required by
  the architecture.
  """

  use Ash.Domain

  resources do
    resource Cartulary.Memory.Account
    resource Cartulary.Memory.Peer
    resource Cartulary.Memory.Scope
    resource Cartulary.Memory.Session
    resource Cartulary.Memory.Message
    resource Cartulary.Memory.KnowledgeItem
    resource Cartulary.Memory.KnowledgeLifecycleEvent
  end
end
