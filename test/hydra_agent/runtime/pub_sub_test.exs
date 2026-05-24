defmodule HydraAgent.Runtime.PubSubTest do
  use ExUnit.Case, async: true

  alias HydraAgent.Runtime.PubSub

  test "builds stable runtime topics" do
    assert PubSub.workspace_topic(1) == "workspace:1"
    assert PubSub.run_topic(2) == "run:2"
    assert PubSub.conversation_topic(3) == "conversation:3"
  end

  test "conversation delta topic matches conversation topic" do
    assert PubSub.conversation_topic("abc") == "conversation:abc"
  end
end
