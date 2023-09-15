defmodule Common.MediaTransport.DroppedVideoFramesEvent do
  @derive Membrane.EventProtocol
  defstruct [:frames]
end
