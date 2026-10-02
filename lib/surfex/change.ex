defmodule Surfex.Change do
  @moduledoc """
  A **change draft**: work Surfex found, described for the environment's own change
  process (§19). Surfex knows no tracker. It drafts, and the process decides.

  A draft has a title, the problem, what it touches (the spec unit with its text, the tests
  that verify it, the code that implements it, each with its relation's state) and the
  steps the process implies (§18). `drafts/3` makes them from a status: every open mark,
  unmet id and triangle gap, or the items named. `markdown/1` renders one for a person,
  `json/1` a list for tools, and `hand_off/3` gives them to the project's `process:`.
  """

  alias Surfex.Scan

  @enforce_keys [:title, :source, :id, :problem]
  defstruct [:title, :source, :id, :problem, units: [], tests: [], code: [], steps: []]

  @type touched :: %{
          id: String.t(),
          location: String.t() | nil,
          state: atom | nil,
          text: String.t() | nil
        }
  @type t :: %__MODULE__{
          title: String.t(),
          source: :mark | :unmet | :gap | :item,
          id: String.t(),
          problem: String.t(),
          units: [touched],
          tests: [touched],
          code: [touched],
          steps: [String.t()]
        }

  # The process (§18), from a spec that is settled or about to be.
  @steps [
    "Write or update a failing test from the spec's words, and run it: it must fail.",
    "Record the test relation on that failing run (`mix surfex.suggest --accept`).",
    "Change the code until the test is green.",
    "Validate the code relation by evidence: `mix test && mix surfex.confirm --evidence`."
  ]

  @doc """
  The drafts for a status: one per open mark, unmet id and triangle gap, in that order.
  Given `ids`, the drafts for those items instead: a marked spec unit's marks, or a draft
  to change the item. An id that isn't scanned raises. `root` is where the spec files are,
  to quote a unit's text.
  """
  @spec drafts(Surfex.Status.t(), String.t(), [String.t()]) :: [t]
  def drafts(status, root, []) do
    Enum.map(status.marks, &mark(status, root, &1)) ++
      Enum.map(status.unmet, &unmet(status, root, &1)) ++
      Enum.map(status.triangle, &gap(status, root, &1))
  end

  def drafts(status, root, ids) do
    Enum.flat_map(ids, fn id ->
      scan =
        Enum.find_value(status.scans, fn {{_kind, sid}, scan} -> sid == id and scan end) ||
          raise ArgumentError, "#{id} is not scanned: no spec unit, code item or test has that id"

      case Enum.filter(status.marks, &(&1.unit == id)) do
        [] -> [item(status, root, scan)]
        marks -> Enum.map(marks, &mark(status, root, &1))
      end
    end)
  end

  defp mark(status, root, m) do
    %{
      touches(status, root, {:spec, m.unit})
      | title: "Spec needs an update: #{m.unit}",
        source: :mark,
        id: m.unit,
        problem: "#{m.note}\n\n(#{m.by}, #{m.at})",
        steps: [
          "Rewrite the spec unit to say what the result should be (the problem above)." | @steps
        ]
    }
  end

  defp unmet(status, root, %{scan: scan, requires: requires}) do
    types = Enum.join(requires, " or ")

    %{
      touches(status, root, {scan.kind, scan.id})
      | title: "Unmet: #{scan.kind} #{scan.id} needs #{types}",
        source: :unmet,
        id: scan.id,
        problem:
          "The require: policy says #{scan.kind} #{scan.id} must take part in a #{types} " <>
            "relation, and it doesn't.",
        steps: [settle(scan) | @steps]
    }
  end

  defp gap(status, root, g) do
    {title, problem} =
      case g.gap do
        :no_test ->
          {"Triangle gap: #{g.spec} has no verifying test",
           "Code implements #{g.spec}, and no test verifies it."}

        :test_misses_code ->
          {"Triangle gap: #{g.test} verifies #{g.spec} but calls none of its code",
           "#{g.test} verifies #{g.spec}, and exercises none of the code that implements it."}

        :code_untested ->
          {"Triangle gap: #{g.code} implements #{g.spec} but no verifying test calls it",
           "#{g.code} implements #{g.spec}, and no test verifying it exercises that code."}
      end

    %{
      touches(status, root, {:spec, g.spec})
      | title: title,
        source: :gap,
        id: g.spec,
        problem: problem,
        steps: ["Check the spec unit states the claim the missing side must meet." | @steps]
    }
  end

  defp item(status, root, %Scan{} = scan) do
    %{
      touches(status, root, {scan.kind, scan.id})
      | title: "Change to #{scan.kind} #{scan.id}",
        source: :item,
        id: scan.id,
        problem: "Describe the change to #{scan.kind} #{scan.id}, and why.",
        steps: ["Settle the spec's words first: the change starts in the spec." | @steps]
    }
  end

  defp settle(%Scan{kind: :code}),
    do: "Describe it in the spec, or excuse it by a class (§8) if the spec shouldn't."

  defp settle(_scan), do: "Settle the spec's words first: the change starts in the spec."

  # What a unit, code item or test touches: the spec units, tests and code related to it.
  defp touches(status, root, {kind, id} = key) do
    related =
      for %{relation: {type, a, b}, state: state} <- status.relations,
          state != :retired,
          key in [a, b],
          {other_kind, other} = if(a == key, do: b, else: a),
          do: {type, other_kind, other, state}

    self = touched(status, root, key, nil)

    others = fn kinds ->
      for {_type, k, other, state} <- related,
          k in kinds,
          do: touched(status, root, {k, other}, state)
    end

    base = %__MODULE__{title: "", source: :item, id: id, problem: ""}

    case kind do
      :spec -> %{base | units: [self], tests: others.([:test]), code: others.([:code])}
      :code -> %{base | units: others.([:spec]), tests: others.([:test]), code: [self]}
      :test -> %{base | units: others.([:spec]), tests: [self], code: others.([:code])}
      _ -> %{base | units: others.([:spec]), code: others.([:code])}
    end
  end

  defp touched(status, root, {kind, id}, state) do
    scan = Map.get(status.scans, {kind, id})

    %{
      id: id,
      kind: kind,
      location: scan && location(scan.location),
      state: state,
      text: if(kind == :spec and scan, do: text(root, scan.location))
    }
  end

  defp location(%{file: file, lines: {first, last}}), do: "#{file}:#{first}-#{last}"
  defp location(%{file: file}), do: file

  # The unit's text as it stands, quoted from its file.
  defp text(root, %{file: file, lines: {first, last}}) do
    path = Path.join(root, file)

    if File.regular?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.slice((first - 1)..(last - 1)//1)
      |> Enum.join("\n")
      |> String.trim_trailing()
    end
  end

  defp text(_root, _location), do: nil

  @doc "A draft as markdown, for a person or an issue body."
  @spec markdown(t) :: String.t()
  def markdown(%__MODULE__{} = d) do
    touches =
      for {label, items} <- [{"spec", d.units}, {"test", d.tests}, {"code", d.code}],
          t <- items,
          do: touched_markdown(label, t)

    steps = d.steps |> Enum.with_index(1) |> Enum.map_join("\n", fn {s, n} -> "#{n}. #{s}" end)

    """
    # #{d.title}

    ## Problem

    #{d.problem}

    ## Touches

    #{Enum.join(touches, "\n")}

    ## Steps

    #{steps}
    """
  end

  defp touched_markdown(label, t) do
    where = if t.location, do: " (#{t.location})", else: ""
    state = if t.state, do: ": #{t.state}", else: ""
    line = "- #{label} `#{t.id}`#{where}#{state}"

    case t.text do
      nil ->
        line

      text ->
        line <> "\n\n" <> Enum.map_join(String.split(text, "\n"), "\n", &"  > #{&1}") <> "\n"
    end
  end

  @doc "Drafts as JSON, for tools and agents."
  @spec json([t]) :: String.t()
  def json(drafts) do
    drafts
    |> Enum.map(fn d ->
      %{
        "title" => d.title,
        "source" => Atom.to_string(d.source),
        "id" => d.id,
        "problem" => d.problem,
        "units" => Enum.map(d.units, &touched_json/1),
        "tests" => Enum.map(d.tests, &touched_json/1),
        "code" => Enum.map(d.code, &touched_json/1),
        "steps" => d.steps
      }
    end)
    |> :json.encode(&encode/2)
    |> IO.iodata_to_binary()
  end

  defp touched_json(t),
    do: %{
      "id" => t.id,
      "location" => t.location,
      "state" => t.state && Atom.to_string(t.state),
      "text" => t.text
    }

  # OTP's encoder writes any atom but :null as a string: nil must reach tools as null.
  defp encode(nil, _encoder), do: "null"
  defp encode(value, encoder), do: :json.encode_value(value, encoder)

  @doc """
  Hands drafts to the project's change process (`process:`, §19): `:print` gives each
  draft's markdown; `{:command, argv}` runs the command once per draft, in `root`, with
  `{title}`, `{body}` (the markdown) and `{file}` (a file holding it) substituted into
  `argv`, never through a shell. The first command to exit non-zero stops the hand-off,
  with its output. Returns each draft's output.
  """
  @spec hand_off([t], :print | {:command, [String.t()]}, String.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def hand_off(drafts, :print, _root), do: {:ok, Enum.map(drafts, &markdown/1)}

  def hand_off(drafts, {:command, [command | args]}, root) do
    Enum.reduce_while(drafts, {:ok, []}, fn draft, {:ok, outputs} ->
      body = markdown(draft)
      file = Path.join(System.tmp_dir!(), "surfex-draft-#{System.unique_integer([:positive])}.md")
      File.write!(file, body)

      argv =
        Enum.map(args, fn arg ->
          arg
          |> String.replace("{title}", draft.title)
          |> String.replace("{body}", body)
          |> String.replace("{file}", file)
        end)

      {output, status} = System.cmd(command, argv, cd: root, stderr_to_stdout: true)
      File.rm!(file)

      case status do
        0 ->
          {:cont, {:ok, outputs ++ [output]}}

        n ->
          {:halt,
           {:error, "#{command} exited with #{n} handing off \"#{draft.title}\":\n#{output}"}}
      end
    end)
  end
end
