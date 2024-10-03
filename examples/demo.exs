defmodule OpenAIWebSocket do
  use WebSockex
  require Logger

  def start_link(opts) do
    WebSockex.start_link(
      "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-10-01",
      __MODULE__,
      %{parent: self()},
      opts
    )
  end

  def handle_frame(frame, state) do
    send(state.parent, {:websocket_frame, frame})
    {:ok, state}
  end

  def send_frame(ws, frame) do
    WebSockex.send_frame(ws, {:text, frame})
  end
end

defmodule CreateResponseEvent do
  @derive Membrane.EventProtocol
  defstruct []
end

defmodule OpenAIElement do
  use Membrane.Endpoint
  require Membrane.Logger

  def_input_pad :input, accepted_format: _any
  # def_output_pad :output, accepted_format: _any

  def_options websocket_opts: []

  @impl true
  def handle_init(_ctx, opts) do
    {:ok, ws} = OpenAIWebSocket.start_link(opts.websocket_opts)
    {[], %{ws: ws}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    # buffer preprocessing
    dbg(buffer, label: "SENT BUFFER")
    frame = Jason.encode(%{type: "input_audio_buffer.append", audio: buffer.payload})
    :ok = OpenAIWebSocket.send_frame(state.ws, frame)
    {[], state}
  end

  @impl true
  def handle_parent_notification(:create_response, _ctx, state) do
    create_response(state.ws)
    {[], state}
  end

  @impl true
  def handle_event(:input, %CreateResponseEvent{}, _ctx, state) do
    create_response(state.ws)
    {[], state}
  end

  @impl true
  def handle_event(pad, event, _ctx, state) do
    Membrane.Logger.info("Event #{inspect(event)} from pad #{inspect(pad)} ignored.")
    {[], state}
  end

  defp create_response(ws) do
    # frame = Jason.encode(%{type: "input_audio_buffer.commit"})
    frame = Jason.encode(%{type: "response.create"})
    :ok = OpenAIWebSocket.send_frame(state.ws, frame)
  end

  @impl true
  def handle_info({:websocket_frame, frame}, _ctx, state) do
    decoded_frame = Jason.decode!(frame)
    dbg(decoded_frame, label: "DECODED FRAME")
    {[], state}
  end
end

defmodule BrowserToOpenAi do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, opts) do
    spec =
      child(:webrtc_source, %Membrane.WebRTC.Source{
        signaling: {:websocket, port: opts[:webrtc_ws_port]}
      })
      |> via_out(:output, options: [kind: :audio])
      |> child(:opus_parser, Membrane.Opus.Parser)
      |> child(:opus_decoder, %Membrane.Opus.Decoder{sample_rate: 24_000})
      |> child(:open_ai, %OpenAIElement{websocket_opts: opts[:openai_ws_opts]})

    self() |> Process.send_after(:create_response, 10_000)

    {[spec: spec], state}
  end

  @impl true
  def handle_info(:create_response, _ctx, state) do
    {[notify_child: {:open_ai, :create_response}], state}
  end

  @impl true
  def handle_element_end_of_stream(:open_ai, :input, _ctx, state) do
    {[terminate: :normal], state}
  end
end

openai_api_key = System.get_env("OPENAI_API_KEY")

openai_ws_opts = [
  extra_headers: [
    {"Authorization", "Bearer " <> openai_api_key},
    {"OpenAI-Beta", "realtime=v1"}
  ]
]

{:ok, _supervisor, pipeline} =
  Membrane.Pipeline.start_link(BrowserToOpenAi,
    openai_ws_opts: openai_ws_opts,
    webrtc_ws_port: 8829
  )

{:ok, _server} =
  :inets.start(:httpd,
    bind_address: ~c"localhost",
    port: 8000,
    document_root: ~c"#{__DIR__}/assets/browser_to_file",
    server_name: ~c"webrtc",
    server_root: "/tmp"
  )

Process.monitor(pipeline)

receive do
  {:DOWN, _ref, :process, ^pipeline, _reason} -> :ok
end
