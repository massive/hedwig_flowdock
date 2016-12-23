defmodule Hedwig.Adapters.Flowdock do
  use Hedwig.Adapter

  require Logger
  alias Hedwig.Adapters.Flowdock.StreamingConnection, as: SC
  alias Hedwig.Adapters.Flowdock.RestConnection, as: RC

  defmodule State do
    defstruct conn: nil,
      rest_conn: nil,
      flows: %{},
      user_id: nil,
      name: nil,
      opts: nil,
      robot: nil,
      users: %{}
  end

  def init({robot, opts}) do
    Logger.info "#{opts[:name]} is Booting up..."

    {:ok, r_conn} = RC.start_link(opts)
    flows = GenServer.call(r_conn, :flows)

    {:ok, s_conn} = SC.start_link(Keyword.put(opts, :flows, flows))
    users = GenServer.call(r_conn, :users)
    reduced_users = reduce(users, %{})
    user = Enum.find(users, fn u -> u["nick"] == opts[:name] end)

    {:ok, %State{conn: s_conn, rest_conn: r_conn, opts: opts, robot: robot, users: reduced_users, user_id: user["id"]}}
  end

  def handle_cast({:send, msg}, %{rest_conn: r_conn} = state) do
    GenServer.cast(r_conn, {:send_message, flowdock_message(msg)})

    {:noreply, state}
  end

  def handle_cast({:send_raw, msg}, %{rest_conn: r_conn} = state) do
    GenServer.cast(r_conn, {:send_message, msg})

    {:noreply, state}
  end

  def handle_cast({:reply, %{user: user, text: text} = msg}, %{rest_conn: r_conn} = state) do
    msg = %{msg | text: "@#{user.name}: #{text}"}

    GenServer.cast(r_conn, {:send_message, flowdock_message(msg)})
    {:noreply, state}
  end

  def handle_cast({:emote, %{text: text, user: user} = msg}, %{rest_conn: r_conn} = state) do
    msg = %{msg | text: "@#{user.name}: #{text}"}

    GenServer.cast(r_conn, {:send_message, flowdock_message(msg)})
    {:noreply, state}
  end

  def handle_cast({:message, content, flow_id, user, thread_id}, %{robot: robot, users: users} = state) do
    msg = %Hedwig.Message{
      ref: make_ref(),
      room: flow_id,
      private: %{
        thread_id: thread_id
      },
      text: content,
      type: "message",
      user: %Hedwig.User{
        id: user,
        name: users[user]["nick"]
      }
    }

    if msg.text do
      Hedwig.Robot.handle_in(robot, msg)
    end
    {:noreply, state}
  end

  def handle_call({:flows, flows}, _from, state) do
    {:reply, nil, %{state | flows: flows}}
  end

  def handle_call({:robot_name}, _from, %{opts: opts} = state) do
    {:reply, opts[:name], state}
  end

  def handle_info(:connection_ready, %{robot: robot} = state) do
    Hedwig.Robot.handle_connect(robot)
    {:noreply, state}
  end

  def handle_info(msg, %{robot: robot} = state) do
    Hedwig.Robot.handle_in(robot, msg)
    {:noreply, state}
  end

  defp flowdock_message(%Hedwig.Message{} = msg, overrides \\ %{}) do
    defaults = Map.merge(%{flow: msg.room, content: msg.text, event: msg.type}, overrides)
    if msg.private.thread_id do
      Map.merge(%{thread_id: msg.private[:thread_id]}, defaults)
    end
  end

  defp reduce(collection, acc) do
    Enum.reduce(collection, acc, fn item, acc ->
      Map.put(acc, "#{item["id"]}", item)
    end)
  end

  def parameterize_flow(flow) do
    "#{flow["organization"]["parameterized_name"]}/#{flow["parameterized_name"]}"
  end
end
