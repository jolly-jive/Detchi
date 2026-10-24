defmodule Detchi.ConfigTest do
  use ExUnit.Case, async: true

  alias Detchi.Config
  alias Detchi.Config.Issue

  @secret "s3cr3t-community"

  @moduletag :tmp_dir

  defp write(dir, text) do
    path = Path.join(dir, "detchi.yml")
    File.write!(path, text)
    path
  end

  test "loads the sample config", %{tmp_dir: dir} do
    path = write(dir, File.read!("test/fixtures/config/sample.yml"))
    assert {:ok, %Config{targets: [_, _, _]}, []} = Config.load(path)
  end

  test "reports a file that cannot be read" do
    assert {:error, [%Issue{reason: :file_error, detail: [errno: :enoent]} = issue]} =
             Config.load("/nonexistent/detchi.yml")

    assert Issue.format(issue, "/nonexistent/detchi.yml") ==
             "/nonexistent/detchi.yml: error: cannot read the file (enoent)"
  end

  test "formats issues as file:line:column", %{tmp_dir: dir} do
    path = write(dir, "compression: xz\n" <> "targets: []\n")
    assert {:error, issues} = Config.load(path)

    assert Enum.map(issues, &Issue.format(&1, "detchi.yml")) == [
             "detchi.yml:1:14: error: compression: must be one of: gzip, zstd",
             "detchi.yml:2:10: error: targets: must not be empty"
           ]
  end

  test "reports an anchor on a flow collection", %{tmp_dir: dir} do
    path = write(dir, "x-probes: &p [{ name: ping, protocol: icmp }]\n")
    assert {:error, [issue]} = Config.load(path)

    assert Issue.format(issue, "detchi.yml") ==
             "detchi.yml:1:11: error: an anchor on a [...] or {...} collection is not supported; " <>
               "write the collection in block style"
  end

  describe "credentials never appear" do
    # Each of these holds the secret where a careless message would quote it
    # (docs/basic-design.md, 7.1 and 7.8).
    @broken [
      # Broken YAML: yamerl's own error holds the text around the spot.
      "credentials: { c: { version: v2c, community: \"#{@secret} }\n",
      "credentials:\n  c: { version: v2c, community: '#{@secret}\n",
      # A missing space turns the secret into a key.
      "credentials: { c: { version: v2c, community:#{@secret} } }\ntargets: []\n",
      "targets:\n  - { name: t, host: h, snmp: { community:#{@secret} }, probes: [] }\n",
      # The secret as a value of the wrong type or in the wrong place.
      "credentials: { c: { version: #{@secret}, community: x } }\ntargets: []\n",
      "credentials: { c: { version: v2c, community: [#{@secret}] } }\ntargets: []\n",
      "credentials: { #{@secret}: { version: v2c, community: x } }\ntargets: []\n",
      "targets:\n  - { name: #{@secret}, host: \"#{@secret}!\", probes: [{ name: a, protocol: #{@secret} }] }\n",
      "targets:\n  - { name: t, host: h, snmp: { credential: #{@secret} }, probes: [{ name: a, protocol: icmp }] }\n",
      "#{@secret}: 1\ntargets: []\n",
      "compression: #{@secret}\ntargets: []\n"
    ]

    for {text, index} <- Enum.with_index(@broken) do
      test "in errors, case #{index}", %{tmp_dir: dir} do
        path = write(dir, unquote(text))
        assert {:error, issues} = Config.load(path)

        for issue <- issues do
          refute Issue.format(issue, path) =~ "s3cr3t"
          refute inspect(issue) =~ "s3cr3t"
        end
      end
    end

    test "in an inspected config", %{tmp_dir: dir} do
      path = write(dir, File.read!("test/fixtures/config/sample.yml"))
      assert {:ok, config, []} = Config.load(path)

      assert [%{snmp: %{credential: credential}} | _] = config.targets
      assert credential.community == @secret
      refute inspect(config, limit: :infinity, printable_limit: :infinity) =~ "s3cr3t"
    end
  end
end
