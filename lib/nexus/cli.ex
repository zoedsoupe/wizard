defmodule Nexus.CLI do
  @moduledoc """
  Nexus.CLI provides a macro-based DSL for defining command-line interfaces with commands,
  flags, and positional arguments using structured ASTs with structs.
  """

  alias Nexus.CLI.Validation, as: V

  alias Nexus.CLI.Argument
  alias Nexus.CLI.Command
  alias Nexus.CLI.Dispatcher
  alias Nexus.CLI.Flag
  alias Nexus.CLI.Help
  alias Nexus.CLI.Input
  alias Nexus.CLI.Validation.ValidationError

  alias Nexus.Parser

  @typedoc "Represents the CLI spec, basically a list of `Command.t()` spec"
  @type ast :: list(Command.t())

  @typedoc "Represent all possible value types of an command argument or flag value"
  @type value ::
          :boolean
          | :string
          | :integer
          | :float
          | {:list, value}
          | {:enum, list(atom | String.t())}

  @typedoc """
  Represents an final-user error while executing a command

  Need to inform the return code of the program and a reason of the error
  """
  @type error :: {code :: integer, reason :: String.Chars.t()}

  @doc """
  Sets the version of the CLI

  Default implementation fetches from the `mix.exs`
  """
  @callback version :: String.t()

  @doc """
  Sets the CLI description

  Default implementation fetches from `@moduledoc`, however
  take in account that if you're compiling your app as an escript
  or single binary (rg. burrito) the `@moduledoc` attribute may be
  not available on runtime

  Fetch module documentation on compile-time is marked to Elixir 2.0
  check https://github.com/elixir-lang/elixir/issues/8095
  """
  @callback description :: String.t()

  @doc """
  Custom banners can be set
  """
  @callback banner :: String.t()

  @doc """
  Function that receives the current command being used and its args

  If a subcommand is being used, then the first argument will be a list
  of atoms representing the command path

  Note that when returning `:ok` from this function, your program will
  exit with a success code, generally `0`

  To inform errors, check the `Nexus.CLI.error()` type

  ## Examples

      @impl Nexus.CLI
      def handle_input(:my_cmd, _), do: nil

      def handle_inpu([:my, :nested, :cmd], _), do: nil
  """
  @callback handle_input(cmd :: atom, input :: Input.t()) :: :ok | {:error, error}
  @callback handle_input(cmd :: list(atom), input :: Input.t()) :: :ok | {:error, error}

  @optional_callbacks banner: 0

  @type t :: %__MODULE__{
          otp_app: atom,
          name: atom,
          spec: ast,
          version: String.t(),
          description: String.t(),
          handler: module
        }

  defstruct [:name, :spec, :version, :description, :handler, :otp_app]

  defmodule Input do
    @moduledoc """
    Represents a command input, with args and flags values parsed

    - `flags` is a map with keys as flags names and values as flags values
    - `args` is a map of positional arguments where keys are the arguments
    names defined with the `:as` option on the `value/2` macro
    - `value` is a single value term that represents the command value itself

    If the command define multiple (positional) arguments, `value` will be `nil`
    and `args` willbe populated, otherwise `args` will be an empty map and `value`
    will be populated
    """

    @type t :: %__MODULE__{flags: %{atom => term}, args: %{atom => term}, value: term | nil}

    defstruct [:flags, args: %{}, value: nil]
  end

  defmodule Command do
    @moduledoc "Represents a command or subcommand."

    alias Nexus.CLI.Argument
    alias Nexus.CLI.Flag

    @type t :: %__MODULE__{
            name: atom | nil,
            description: String.t() | nil,
            subcommands: list(t),
            flags: list(Flag.t()),
            args: list(Argument.t())
          }

    defstruct name: nil,
              description: nil,
              subcommands: [],
              flags: [],
              args: []
  end

  defmodule Flag do
    @moduledoc "Represents a flag (option) for a command."

    @type t :: %__MODULE__{
            name: atom | nil,
            short: atom | nil,
            type: Nexus.CLI.value(),
            required: boolean,
            default: term,
            description: String.t() | nil
          }

    defstruct name: nil,
              short: nil,
              type: :boolean,
              required: false,
              default: false,
              description: nil
  end

  defmodule Argument do
    @moduledoc "Represents a positional argument for a command."

    @type t :: %__MODULE__{
            name: atom | nil,
            type: Nexus.CLI.value(),
            required: boolean,
            default: term | nil
          }

    defstruct name: nil,
              type: :string,
              required: false,
              default: nil
  end

  defmacro __using__(opts \\ []) when is_list(opts) do
    mod = __CALLER__.module
    otp_app = opts[:otp_app] || raise ValidationError, "missing :otp_app option"
    name = String.to_atom(opts[:name] || Macro.underscore(mod))
    cli = %__MODULE__{name: name, otp_app: otp_app}

    quote do
      import Nexus.CLI,
        only: [
          defcommand: 2,
          subcommand: 2,
          value: 2,
          flag: 2,
          short: 1,
          description: 1
        ]

      Module.put_attribute(__MODULE__, :cli, unquote(Macro.escape(cli)))
      Module.register_attribute(__MODULE__, :cli_commands, accumulate: true)
      Module.register_attribute(__MODULE__, :cli_command_stack, accumulate: false)
      Module.register_attribute(__MODULE__, :cli_flag_stack, accumulate: false)

      @before_compile Nexus.CLI

      @behaviour Nexus.CLI

      @impl Nexus.CLI
      def version do
        vsn =
          unquote(otp_app)
          |> Application.spec()
          |> Keyword.get(:vsn, ~c"")

        for c <- vsn, into: "", do: <<c>>
      end

      defoverridable version: 0
    end
  end

  # Macro to define a top-level command
  defmacro defcommand(name, do: block) do
    quote do
      # Initialize a new Command struct
      command = %Command{name: unquote(name)}

      # Push the command onto the command stack
      Nexus.CLI.__push_command__(command, __MODULE__)

      # Execute the block to populate subcommands, flags, and args
      unquote(block)

      # Finalize the command and accumulate it
      Nexus.CLI.__finalize_command__(__MODULE__)
    end
  end

  # Macro to define a subcommand within the current command
  defmacro subcommand(name, do: block) do
    quote do
      # Initialize a new Command struct for the subcommand
      subcommand = %Command{name: unquote(name)}

      # Push the subcommand onto the command stack
      Nexus.CLI.__push_command__(subcommand, __MODULE__)

      # Execute the block to populate subcommands, flags, and args
      unquote(block)

      # Finalize the subcommand and attach it to its parent
      Nexus.CLI.__finalize_subcommand__(__MODULE__)
    end
  end

  # Macro to define a positional argument
  defmacro value(type, opts \\ []) do
    quote do
      flag_stack = Module.get_attribute(__MODULE__, :cli_flag_stack)

      if not is_nil(flag_stack) and not Enum.empty?(flag_stack) do
        # we're inside a flag
        Nexus.CLI.__set_flag_value__(unquote(type), unquote(opts), __MODULE__)
      else
        # we're inside cmd/subcmd
        Nexus.CLI.__set_command_value__(unquote(type), unquote(opts), __MODULE__)
      end
    end
  end

  # Macro to define a flag
  defmacro flag(name, do: block) do
    quote do
      # Initialize a new Flag struct
      flag = %Flag{name: unquote(name)}

      # Push the flag onto the flag stack
      Nexus.CLI.__push_flag__(flag, __MODULE__)

      # Execute the block to set flag properties
      unquote(block)

      # Finalize the flag and add it to its parent
      Nexus.CLI.__finalize_flag__(__MODULE__)
    end
  end

  # Macro to define a short alias for a flag
  defmacro short(short_name) do
    quote do
      Nexus.CLI.__set_flag_short__(unquote(short_name), __MODULE__)
    end
  end

  # Macro to define a description for a command, subcommand, or flag
  defmacro description(desc) do
    quote do
      Nexus.CLI.__set_description__(unquote(desc), __MODULE__)
    end
  end

  # Internal functions to manage the command stack and build the AST

  # Push a command or subcommand onto the command stack
  def __push_command__(command, module) do
    Module.put_attribute(module, :cli_command_stack, [
      command | Module.get_attribute(module, :cli_command_stack) || []
    ])
  end

  def __finalize_command__(module) do
    [command | rest] = Module.get_attribute(module, :cli_command_stack)

    command =
      command
      |> __process_command_arguments__()
      |> V.validate_command()
      |> __inject_help__()

    existing_commands = Module.get_attribute(module, :cli_commands) || []

    if Enum.any?(existing_commands, &(&1.name == command.name)) do
      raise ValidationError, "Duplicate command name: '#{command.name}'."
    end

    Module.put_attribute(module, :cli_commands, command)
    Module.put_attribute(module, :cli_command_stack, rest)
  end

  def __finalize_subcommand__(module) do
    [subcommand, parent | rest] = Module.get_attribute(module, :cli_command_stack)

    subcommand =
      subcommand
      |> __process_command_arguments__()
      |> V.validate_command()
      |> __inject_help__()

    # Ensure no duplicate subcommand names within the parent
    if Enum.any?(parent.subcommands, &(&1.name == subcommand.name)) do
      raise ValidationError,
            "Duplicate subcommand name: '#{subcommand.name}' within command '#{parent.name}'."
    end

    updated_parent = Map.update!(parent, :subcommands, fn subs -> [subcommand | subs] end)
    Module.put_attribute(module, :cli_command_stack, [updated_parent | rest])
  end

  # Push a flag onto the flag stack
  def __push_flag__(flag, module) do
    Module.put_attribute(module, :cli_flag_stack, [
      flag | Module.get_attribute(module, :cli_flag_stack) || []
    ])
  end

  def __set_flag_value__(type, opts, module) do
    [flag | rest] = Module.get_attribute(module, :cli_flag_stack)

    Module.put_attribute(module, :cli_flag_stack, [
      Map.merge(flag, %{
        type: type,
        required: Keyword.get(opts, :required, false),
        default: Keyword.get(opts, :default)
      })
      | rest
    ])
  end

  def __set_command_value__(type, opts, module) do
    [current | rest] = Module.get_attribute(module, :cli_command_stack)

    arg = %Argument{
      name: Keyword.get(opts, :as),
      type: type,
      required: Keyword.get(opts, :required, false),
      default: Keyword.get(opts, :default)
    }

    updated = Map.update!(current, :args, fn args -> args ++ [arg] end)
    Module.put_attribute(module, :cli_command_stack, [updated | rest])
  end

  def __set_flag_short__(short_name, module) do
    [flag | rest] = Module.get_attribute(module, :cli_flag_stack)
    updated_flag = Map.put(flag, :short, short_name)
    Module.put_attribute(module, :cli_flag_stack, [updated_flag | rest])
  end

  # Set the description for the current command, subcommand, or flag
  def __set_description__(desc, module) do
    flag_stack = Module.get_attribute(module, :cli_flag_stack) || []

    if Enum.empty?(flag_stack) do
      # if we're not operating on a flag, so it's a command/subcommand
      stack = Module.get_attribute(module, :cli_command_stack) || []
      [current | rest] = stack
      updated = Map.put(current, :description, desc)
      Module.put_attribute(module, :cli_command_stack, [updated | rest])
    else
      [flag | rest] = flag_stack
      updated_flag = Map.put(flag, :description, desc)
      Module.put_attribute(module, :cli_flag_stack, [updated_flag | rest])
    end
  end

  def __finalize_flag__(module) do
    [flag | rest_flag] = Module.get_attribute(module, :cli_flag_stack)
    Module.put_attribute(module, :cli_flag_stack, rest_flag)

    [current | rest] = Module.get_attribute(module, :cli_command_stack)

    flag = V.validate_flag(flag)
    flag = if flag.type == :boolean, do: Map.put_new(flag, :default, false), else: flag

    updated = Map.update!(current, :flags, fn flags -> [flag | flags] end)
    Module.put_attribute(module, :cli_command_stack, [updated | rest])
  end

  def __process_command_arguments__(command) do
    unnamed_args = Enum.filter(command.args, &(&1.name == nil))

    cond do
      Enum.empty?(unnamed_args) ->
        # All arguments have names
        command

      length(command.args) == 1 ->
        # Single unnamed argument; set its name to the command's name
        [arg] = command.args
        arg = %{arg | name: command.name}
        %{command | args: [arg]}

      true ->
        # Multiple arguments; all must have names
        raise "All arguments must have names when defining multiple arguments in command '#{command.name}'. Please specify 'as: :name' option."
    end
  end

  defp __inject_help__(%Command{name: :help} = command) do
    command
  end

  defp __inject_help__(%Command{} = command) do
    command
    |> ensure_help_flag()
    |> inject_help_into_subcommands()
  end

  # Ensures that a command has the '--help' and '-h' flags
  defp ensure_help_flag(%Command{flags: flags} = command) do
    if Enum.any?(flags, &(&1.name == :help)) do
      command
    else
      help_flag = %Flag{
        name: :help,
        short: :h,
        type: :boolean,
        required: false,
        default: false,
        description: "Prints help information."
      }

      %{command | flags: [help_flag | flags]}
    end
  end

  # Recursively injects help into all subcommands
  defp inject_help_into_subcommands(%Command{subcommands: subcommands} = command) do
    updated_subcommands = Enum.map(subcommands, &__inject_help__/1)
    %{command | subcommands: updated_subcommands}
  end

  defmacro __before_compile__(env) do
    commands = Module.get_attribute(env.module, :cli_commands)
    cli = Module.get_attribute(env.module, :cli)

    quote do
      @impl Nexus.CLI
      def description, do: @moduledoc

      defoverridable description: 0

      @doc false
      def __nexus_spec__ do
        %{
          unquote(Macro.escape(cli))
          | description: description(),
            spec: unquote(Macro.escape(commands)),
            version: version(),
            handler: __MODULE__
        }
      end

      @doc """
      Given the system `argv`, tries to parse the input
      and dispatches the parsed command to the handler
      module (aka `#{__MODULE__}`)

      If it fails it will display the CLI help. This
      convenience function can be used as delegated
      of an Escript or Mix.Task module

      For more information chekc `Nexus.CLI.__run_cli__`
      """
      def execute(argv) when is_list(argv) or is_binary(argv) do
        # Nexus.Parser will tokenize the whole input
        # Mix tasks already split the argv into a list
        argv = List.wrap(argv) |> Enum.join(" ")
        Nexus.CLI.__run_cli__(__nexus_spec__(), argv)
      end

      @doc """
      Prints CLI documentation based into the CLI spec defined given a command path

      For more information, check `Nexus.CLI.Help`

      It receives an optional command path, for displaying
      subcommands help, for example

      ## Examples

          iex> #{inspect(__MODULE__)}.display_help()
          # prints help for the CLI itself showing all available commands and flags
          :ok

          iex> #{inspect(__MODULE__)}.display_help([:root])
          # prints help for the `root` cmd showing all available subcommands and flags
          :ok

          iex> #{inspect(__MODULE__)}.display_help([:root, :nested])
          # prints help for the `root -> :nested` subcmd showing all available subcommands and flags
          :ok
      """
      def display_help(path \\ []) do
        alias Nexus.CLI
        Help.display(__nexus_spec__(), path)
      end
    end
  end

  @doc """
  Given a the CLI spec and the user input,
  tries to parse the input against the spec and dispatches the
  parsed result to the CLI handler module - the one that imeplement `Nexus.CLI`
  behaviour.

  If the dispatchment is successfull and the `handle_input/2` return an `:ok`,
  then it stops the VM with a success code.

  If there is a parsing error it will display the CLI help and stop the VM with
  error code.

  If `handle_input/2` returns an error, it stops the VM with the desired code.
  """
  @spec __run_cli__(t, binary) :: :ok
  def __run_cli__(%__MODULE__{} = cli, input) when is_binary(input) do
    with {:ok, result} <- Parser.parse_ast(cli, input),
         :ok <- Dispatcher.dispatch(cli, result) do
      System.stop(0)
    else
      {:error, reason} when is_list(reason) ->
        Help.display(cli)
        System.stop(1)

      {:error, {code, reason}} ->
        if reason, do: IO.puts(reason)
        System.stop(code)
    end
  end
end
