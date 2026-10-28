defmodule Bunt do
  @moduledoc """
  `Bunt` enables 256 color ANSI coloring in the terminal and gives you the ability to alias colors to more semantic and application-specfic names.



  ### Augment `IO.ANSI`

  `IO.ANSI` provides an interface to write text to the terminal in eight different colors like this:

      ["Hello, ", :red, :bright, "world!"]
      |> IO.ANSI.format
      |> IO.puts

  This will put the word "world!" in bright red.

  To cause as little friction as possible, the interface of `Bunt.ANSI` is 100% adapted from `IO.ANSI`.

  We can use `Bunt` in the same way:

      ["Hello, ", :color202, :bright, "world!"]
      |> Bunt.ANSI.format
      |> IO.puts

  which puts a bright orange-red `"world!"` on the screen.

  `Bunt` also provides a shortcut so we can skip the `format` call.

      ["Hello, ", :color202, :bright, "world!"]
      |> Bunt.puts

  and since nobody can remember that `:color202` is basically `:orangered`, you can use `:orangered` directly.



  ### Named colors

  The following colors were given names, so you can use them in style:

      [:gold, "Look, it's really gold text!"]
      |> Bunt.puts

  Replace `:gold` with any of these values:

      darkblue      mediumblue    darkgreen     darkslategray darkcyan
      deepskyblue   springgreen   aqua          dimgray       steelblue
      darkred       darkmagenta   olive         chartreuse    aquamarine
      greenyellow   chocolate     goldenrod     lightgray     beige
      lightcyan     fuchsia       orangered     hotpink       darkorange
      coral         orange        gold          khaki         moccasin
      mistyrose     lightyellow

  You can see all supported colors by cloning the repo and running:

      $ mix run script/colors.exs

  ### User-defined color aliases

  But since all these colors are hard to remember, you can alias them in your config.exs:

      # I tend to start the names of my color aliases with an underscore
      # but this is, naturally, not a must.

      config :bunt, color_aliases: [_cupcake: :color205]

  Then you can use these keys instead of the standard colors in your code:

      [:_cupcake, "Hello World!"]
      |> Bunt.puts

  Use this to give your colors semantics. They get easier to change later that way. (A colleague of mine shouted "It's CSS for console applications!" when he saw this and although that is ... well, not true, I really like the sentiment! :+1:)


  """
  alias Bunt.ANSI

  @version Mix.Project.config()[:version]

  @doc """
  Formats and writes `value` to `stdout`, similar to `write/1`, but adds a newline at the end.

  ## Examples

      Bunt.puts([:bright, :green, "Success!"])
  """
  def puts(value \\ "") do
    value
    |> format
    |> IO.puts()
  end

  @doc """
  Formats and writes `value` to `stderr`.

  ## Examples

      Bunt.puts([:bright, :red, "Warning!"])
  """
  def warn(value \\ "") do
    formatted_value = format(value)
    IO.puts(:stderr, formatted_value)
  end

  @doc """
  Formats and writes `value` to `stdout`.

  ## Examples

      Bunt.write([:bright, :cyan, "Info!"])
  """
  def write(value \\ "") do
    value
    |> format
    |> IO.write()
  end

  def format, do: format("")

  @doc """
  Formats `value` by converting named ANSI sequences into actual ANSI codes.

  ## Examples

      Bunt.format([:bright, :cyan, "Info!"])
  """
  def format(value)
  def format(nil), do: format("")
  def format(text) when is_binary(text), do: text

  def format(list) when is_list(list) do
    list
    |> List.flatten()
    |> ANSI.format()
  end

  @doc "Returns the version of Bunt."
  def version, do: @version
end
