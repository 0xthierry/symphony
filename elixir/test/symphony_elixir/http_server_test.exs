defmodule SymphonyElixir.HttpServerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.HttpServer
  alias SymphonyElixirWeb.Endpoint

  test "child_spec/1 points to start_link/1 with provided opts" do
    assert %{
             id: SymphonyElixir.HttpServer,
             start: {SymphonyElixir.HttpServer, :start_link, [[port: 4321]]}
           } = HttpServer.child_spec(port: 4321)
  end

  test "start_link/1 ignores invalid port values" do
    assert :ignore = HttpServer.start_link(port: -1)
    assert :ignore = HttpServer.start_link(port: "invalid")
  end

  test "start_link/1 returns host resolution errors for invalid hostnames" do
    assert {:error, _reason} =
             HttpServer.start_link(port: 0, host: "definitely-invalid-hostname.invalid")
  end

  test "start_link/1 accepts IPv4 and IPv6 tuple hosts" do
    assert_endpoint_start_result(HttpServer.start_link(port: 0, host: {127, 0, 0, 1}))
    assert_endpoint_start_result(HttpServer.start_link(port: 0, host: {0, 0, 0, 0, 0, 0, 0, 1}))
  end

  test "start_link/1 resolves hostname hosts through inet lookup fallback" do
    assert_endpoint_start_result(HttpServer.start_link(port: 0, host: "localhost"))
  end

  test "bound_port/0 returns nil when the endpoint is not running" do
    stop_endpoint()
    assert HttpServer.bound_port() == nil
  end

  defp assert_endpoint_start_result(result) do
    case result do
      {:ok, pid} ->
        GenServer.stop(pid)
        :ok

      {:error, {:already_started, pid}} ->
        GenServer.stop(pid)
        :ok
    end
  end

  defp stop_endpoint do
    case Process.whereis(Endpoint) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end
end
