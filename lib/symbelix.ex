defmodule Symbelix do
  alias Symbelix.Expression

  @moduledoc """
  Expression parser and evaluator.
  """

  @spec run(source :: String.t(), library :: Module.t()) :: any()
  @doc """
  Runs a program specified by the source code `source` together with
  the function library `library`. Returns the result of the program,
  or an {:error, message} tuple in case of an error.

  ## Examples:

      iex> Symbelix.run("(add 1 2)", Mathematician)
      3

      iex> Symbelix.run("(sub 1 2)", Mathematician)
      {:error, "Unknown function (atom) 'sub' at line 1 with 2 parameter(s): (1 2)"}

      iex> Symbelix.run("(sub (add 1 2) 1)", Mathematician)
      {:error, "Unknown function (atom) 'sub' at line 1 with 2 parameter(s): ((add 1 2) 1)"}

      iex> Symbelix.run("(first [1 2])", ListProcessor)
      1
  """
  def run(source, library, debug \\ fn x, _ -> x end) do
    with {:ok, code} <- Expression.parse(source),
         ^code <- debug.(code, label: "code"),
         {:ok, ast} <- compile(code, library),
         ^ast <- debug.(ast, label: "ast") do
      case ast do
        {:proc, proc} ->
          {:proc, proc} |> debug.([])

        _ ->
          {result, _binding} = Code.eval_quoted(ast)
          result |> debug.([])
      end
    else
      error -> error |> debug.([])
    end
  end

  @doc """
  Compiles a symbolic expression to Elixir AST.

  ## Examples:

      iex> compile([{:atom, 1, 'add'}, {:number, 1, 1}, {:number, 1, 2}], Mathematician)
      {:ok, {:apply, [context: Symbelix.Library, import: Kernel], [Symbelix.TestHelpers.Libraries.Mathematician, :add, [[1, 2]]]}}

      iex> compile([{:atom, 1, 'aliens'}, {:atom, 1, 'built'}, {:atom, 1, 'it'}], Mathematician)
      {:error, "Unknown function (atom) 'aliens' at line 1 with 2 parameter(s): (built it)"}

      iex> compile([{:atom, 1, '<?php'}], PHP)
      {:error, "The module PHP doesn't exist"}

      iex> compile([{:atom, 1, 'public'}], Java)
      {:error, "The module Symbelix.TestHelpers.Libraries.Java doesn't implement Symbelix.Library behaviour"}

      iex> compile([{:atom, 1, 'proc'}, {:atom, 1, 'add'}, {:number, 1, 1}, {:number, 1, 2}], Mathematician)
      {:ok, {:proc, [{:atom, 1, 'add'}, {:number, 1, 1}, {:number, 1, 2}]}}
  """
  def compile([{:atom, _line, 'eval'} | [[{:atom, _, 'proc'} | code]]], library) do
    {:ok, ast} = compile(code, library)

    {:ok, ast}
  end

  def compile([{:atom, _line, 'eval'} | [params]], library) do
    {:ok, ast} = compile(params, library)
    {{:proc, code}, []} = Code.eval_quoted(ast)

    {{:ok, result}, []} = compile(code, library) |> Code.eval_quoted()

    {:ok, result}
  end

  def compile([{:atom, _, 'proc'} | params], _) do
    {:ok, {:proc, params}}
  end

  def compile([{type, line, name} | params], library) do
    if Code.ensure_compiled?(library) do
      values = Enum.map(params, &value_of(&1, library))

      try do
        case library.generate_ast([name] ++ values) do
          {:ok, ast} ->
            {:ok, ast}

          {:error, :no_such_implementation} ->
            values_description =
              params
              |> Enum.map(&show/1)
              |> Enum.join(" ")

            {:error,
             "Unknown function (#{type}) '#{name}' at line #{line} with #{Enum.count(values)} parameter(s): (#{
               values_description
             })"}
        end
      rescue
        UndefinedFunctionError ->
          {:error, "The module #{inspect(library)} doesn't implement Symbelix.Library behaviour"}
      end
    else
      {:error, "The module #{inspect(library)} doesn't exist"}
    end
  end

  def repl(library \\ Symbelix.Library.Standard) do
    unless Process.whereis(Symbelix.Library.Memory) do
      {:ok, memory} = Symbelix.Library.Memory.start_link()
      Process.register(memory, Symbelix.Library.Memory)
    end

    source = IO.gets("> ")

    case source do
      :eof ->
        IO.puts("\nGoodbye")

      "q\n" ->
        IO.puts("Goodbye")

      "r\n" ->
        IO.inspect(IEx.Helpers.recompile(), label: "recompile")
        repl(library)

      source ->
        try do
          run(source, library, &IO.inspect/2)
        rescue
          exception ->
            IO.puts("Error: #{inspect(exception)}")
            IO.inspect(__STACKTRACE__, label: "stacktrace")
        end

        repl(library)
    end
  end

  defp show({:number, _, value}), do: "#{value}"
  defp show({:atom, _, value}), do: "#{value}"
  defp show({:string, _, value}), do: "#{value}"
  defp show({:list, value}), do: inspect(value)
  defp show([x | tail]), do: "(" <> show(x) <> show_tail(tail)

  defp show_tail([x | tail]), do: " " <> show(x) <> show_tail(tail)

  defp show_tail([]), do: ")"

  defp value_of({:number, _, value}, _), do: value
  defp value_of({:atom, _, value}, _), do: value
  defp value_of({:string, _, value}, _), do: value
  defp value_of({:list, value}, binding), do: Enum.map(value, &value_of(&1, binding))

  defp value_of([{:atom, _line, 'proc'} | proc], _) do
    {:proc, Macro.escape(proc)}
  end

  defp value_of(expression, library) when is_list(expression) do
    {:ok, ast} = compile(expression, library)
    ast
  end
end
