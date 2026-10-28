defmodule FileSystem do
  @moduledoc """
  A `GenServer` process to watch file system changes.

  The process receives data from Port, parse event, and send it to the worker
  process.
  """

  @doc """
  Starts a `GenServer` process and linked to the current process.

  ## Options

    * `:dirs` ([string], required), the list of directory to monitor.

    * `:backend` (atom, optional), default backends: `:fs_mac`. Available
      backends: `:fs_mac`, `:fs_inotify`, and `:fs_windows`.

    * `:name` (atom, optional), the `name` of the worker process to subscribe
      to the file system listener. Alternative to using `pid` of the worker
      process.

    * Additional backend implementation options. See backend module documents
      for more details.

  ## Examples

  Start monitoring `/tmp/fs` directory using the default `:fs_mac` backend of
  the current process:

      iex> {:ok, pid} = FileSystem.start_link(dirs: ["/tmp/fs"])
      iex> FileSystem.subscribe(pid)

  Get instant (`latench: 0`) notifications on file changes:

      iex> FileSystem.start_link(dirs: ["/path/to/some/files"], latency: 0)

  Monitor a directory by a process name:

      iex> FileSystem.start_link(backend: :fs_mac, dirs: ["/tmp/fs"], name: :worker)
      iex> FileSystem.subscribe(:worker)

  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    FileSystem.Worker.start_link(options)
  end

  @doc """
  Register the current process as a subscriber of a `file_system` worker.

  The `pid` you subscribed from will now receive messages like:

      {:file_event, worker_pid, {file_path, events}}
      {:file_event, worker_pid, :stop}

  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(pid) do
    GenServer.call(pid, :subscribe)
  end
end
