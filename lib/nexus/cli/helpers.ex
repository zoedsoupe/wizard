defmodule Nexus.CLI.Helpers do
  @moduledoc """
  Common CLI helper functions.
  """

  @doc """
  Prints a success message to the console.
  """
  def say_success(message) do
    IO.puts(IO.ANSI.green() <> message <> IO.ANSI.reset())
  end

  @doc """
  Asks a question and returns the user's input.
  """
  def ask(question) do
    IO.write(question <> " ")
    IO.gets("") |> String.trim()
  end

  @doc """
  Asks a yes/no question and returns true for yes and false for no.
  """
  def yes?(question) do
    case ask(question <> " (y/n)") do
      "y" -> true
      "n" -> false
      _ -> yes?(question)
    end
  end

  @doc """
  Asks a yes/no question and returns true for no and false for yes.
  """
  def no?(question) do
    not yes?(question)
  end
end
