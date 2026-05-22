%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "test/",
          "config/"
        ],
        excluded: []
      },
      strict: true,
      color: true,
      checks: [
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Refactor.MapInto, false},
        {Credo.Check.Warning.LazyLogging, false},
        {Credo.Check.Readability.MaxLineLength, [max_length: 110]},
        {Credo.Check.Design.TagTODO, [exit_status: 0]},
        {Credo.Check.Design.TagFIXME, [exit_status: 0]},
        {Credo.Check.Refactor.Nesting, [max_nesting: 5]},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 25]},
        {Credo.Check.Refactor.LongQuoteBlocks, [max_line_count: 250]},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Readability.PreferImplicitTry, false},
        {Credo.Check.Readability.RedundantBlankLines, false}
      ]
    }
  ]
}
