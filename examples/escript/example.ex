defmodule Escript.Example do
  @moduledoc """
  This is an example on how to use `Nexus` with an
  escript application.

  After defined `:escript` entry into your `project/0` function
  on `mix.exs` and set the `main_module` option, you can safely
  define your commands as usual with `defcommand/2`, CLI config
  and handlers.

  Then you need to call `parse/0` macro, which will inject both
  `parse/1` and `run/1` function, which the latter you can delegate
  from the `main/1` escript funciton, as can seen below.
  """

  use Nexus.CLI, otp_app: :nexus_cli
  alias Nexus.CLI.Helpers

  defcommand :echo do
    description "Command that receives a string as argument and prints it."

    value :string, required: true
  end

  defcommand :greet do
    description "Greets the user by asking his name"


  end

  defcommand :fizzbuzz do
    description "Fizz bUZZ"

    value :integer, required: true
  end

  defcommand :foo_bar do
    description "Teste"

    subcommand :foo do
      description "hello"

      value :string, required: false, default: "hello"
    end

    subcommand :bar do
      description "hello"

      value :string, required: false, default: "hello"
    end
  end

  @impl true
  def version, do: "0.1.0"

  @impl true
  def handle_input(:echo, %{value: value}) do
    IO.puts(value)
  end

  def handle_input(:greet, _args) do
    name = Helpers.ask("Whats your name?")
    Helpers.say_success("Hello, #{name}!")
    :ok
  end

  def handle_input(:fizzbuzz, %{value: value}) when is_integer(value) do
    cond do
      rem(value, 3) == 0 and rem(value, 5) == 0 -> IO.puts("fizzbuzz")
      rem(value, 3) == 0 -> IO.puts("fizz")
      rem(value, 5) == 0 -> IO.puts("buzz")
      true -> IO.puts value
    end
  end

  def handle_input([:foo_bar, :foo], %{value: _}) do
    IO.puts("Issued foo")
    :ok
  end

  def handle_input([:foo_bar, :bar], %{value: _}) do
    IO.puts("Issued bar")
    :ok
  end

  defdelegate main(args), to: __MODULE__, as: :execute
end
