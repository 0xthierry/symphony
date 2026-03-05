defmodule SymphonyElixir.StaticAssetsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.StaticAssets

  test "fetch/1 returns :error for unknown asset paths" do
    assert :error = StaticAssets.fetch("/missing-asset.js")
  end
end
