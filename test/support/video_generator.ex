defmodule ABRTranscoder.VideoGenerator do
  @moduledoc """
  Helper module for generating a test videos with certain durations and keyframe positions.
  """

  @spec generate_video(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def generate_video(opts) do
    base_path = Keyword.fetch!(opts, :base_path)
    keyframe_positions = Keyword.fetch!(opts, :keyframe_positions)

    framerate = Keyword.get(opts, :framerate, 60)
    duration = Keyword.get(opts, :duration, 10.0)
    width = Keyword.get(opts, :width, 1920)
    height = Keyword.get(opts, :height, 1080)
    bitrate = Keyword.get(opts, :bitrate, 3_000_000)
    repeat_headers = Keyword.get(opts, :repeat_headers, true)

    hash =
      :erlang.phash2(
        {framerate, duration, width, height, bitrate, keyframe_positions, repeat_headers}
      )

    path = "#{base_path}/#{hash}"

    if File.exists?(path <> ".flv") do
      {:ok, path <> ".flv"}
    else
      base_command =
        base_generation_command(
          width,
          height,
          framerate,
          bitrate,
          duration,
          keyframe_positions
        )

      with :ok <- generate_video(base_command, path, repeat_headers) do
        {:ok, path <> ".flv"}
      end
    end
  end

  defp generate_key_frame_filter([]), do: "0"

  defp generate_key_frame_filter([pos | positions]) do
    "if(eq(n,#{pos}),1,#{generate_key_frame_filter(positions)})"
  end

  defp base_generation_command(
         width,
         height,
         framerate,
         bitrate,
         duration,
         keyframe_positions
       ) do
    ~w(
      -y -loglevel error -hide_banner -r #{framerate} -f lavfi -i testsrc=size=#{width}x#{height} -crf #{framerate} -t #{duration}
      -force_key_frames expr:#{generate_key_frame_filter(keyframe_positions)}
      -vsync cfr -vcodec libx264 -b:v #{bitrate} -x264-params nal-hrd=cbr -bufsize 1M -pix_fmt yuv420p
      )
  end

  defp generate_video(base_command, path, true) do
    ffmpeg = System.find_executable("ffmpeg")
    # NOTE: we are intentionally generate an mpeg file first so that ffmpeg forces
    # the SPS and PPS before each frame. This doesn't work if we try to generate the FLV file directly
    # so just trust the process and let it be...
    generation_command = base_command ++ ~w(-bsf:v h264_mp4toannexb -f mpegts #{path}.mp4)

    flv_command = ~w(
        -y -loglevel error -hide_banner -f mpegts -copyts -start_at_zero -i #{path}.mp4
        -c copy -muxdelay 0 -muxpreload 0
        -f flv #{path}.flv
      )

    with {_result, 0} <- System.cmd(ffmpeg, generation_command),
         {_result, 0} <- System.cmd(ffmpeg, flv_command) do
      :ok
    else
      {result, _code} -> {:error, result}
    end
  end

  defp generate_video(base_command, path, false) do
    ffmpeg = System.find_executable("ffmpeg")
    command = base_command ++ ~w(-flags +global_header -bsf:v h264_mp4toannexb #{path}.flv)

    case System.cmd(ffmpeg, command) do
      {_reuslt, 0} -> :ok
      {result, _code} -> {:error, result}
    end
  end
end
