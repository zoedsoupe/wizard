defmodule Nexus.CLI.HelpersTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Nexus.CLI.Helpers

  test "say_success/1 prints a success message in green" do
    message = "Success!"
    output = capture_io(fn -> Helpers.say_success(message) end)
    assert output == IO.ANSI.green() <> message <> IO.ANSI.reset() <> "\n"
  end

  test "ask/1 prompts the user with a question and returns input" do
    question = "What's your name?"
    input = "John Doe\n"
    output = capture_io([input: input], fn -> assert Helpers.ask(question) == "John Doe" end)
    assert output == question <> " "
  end

  test "yes?/1 returns true for 'y' and false for 'n'" do
    question = "Do you agree?"

    output = capture_io([input: "y\n"], fn -> assert Helpers.yes?(question) == true end)
    assert output == question <> " (y/n) "

    output = capture_io([input: "n\n"], fn -> assert Helpers.yes?(question) == false end)
    assert output == question <> " (y/n) "
  end

  test "no?/1 returns true for 'n' and false for 'y'" do
    question = "Do you disagree?"

    output = capture_io([input: "n\n"], fn -> assert Helpers.no?(question) == true end)
    assert output == question <> " (y/n) "

    output = capture_io([input: "y\n"], fn -> assert Helpers.no?(question) == false end)
    assert output == question <> " (y/n) "
  end
end
