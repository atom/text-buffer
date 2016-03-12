Random = require 'random-seed'
TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'
{characterIndexForPoint, isEqual: isEqualPoint} = require '../src/point-helpers'
WORDS = require './helpers/words'
SAMPLE_TEXT = require './helpers/sample-text'
TestDecorationLayer = require './helpers/test-decoration-layer'

describe "DisplayLayer", ->
  beforeEach ->
    jasmine.addCustomEqualityTester(require("underscore-plus").isEqual)

  describe "hard tabs", ->
    it "expands hard tabs to their tab stops", ->
      buffer = new TextBuffer(text: '\ta\tbc\tdef\tg\n\th')
      displayLayer = buffer.addDisplayLayer(tabLength: 4)

      expect(displayLayer.getText()).toBe('    a   bc  def g\n    h')

      expectTokens(displayLayer, [
        {text: '    ', close: [], open: ["hard-tab leading-whitespace"]},
        {text: 'a', close: ["hard-tab leading-whitespace"], open: []},
        {text: '   ', close: [], open: ["hard-tab"]},
        {text: 'bc', close: ["hard-tab"], open: []},
        {text: '  ', close: [], open: ["hard-tab"]},
        {text: 'def', close: ["hard-tab"], open: []},
        {text: ' ', close: [], open: ["hard-tab"]},
        {text: 'g', close: ["hard-tab"], open: []},
        {text: '    ', close: [], open: ["hard-tab leading-whitespace"]},
        {text: 'h', close: ["hard-tab leading-whitespace"], open: []},
      ])

      expectPositionTranslations(displayLayer, [
        [Point(0, 0), Point(0, 0)],
        [Point(0, 1), [Point(0, 0), Point(0, 1)]],
        [Point(0, 2), [Point(0, 0), Point(0, 1)]],
        [Point(0, 3), [Point(0, 0), Point(0, 1)]],
        [Point(0, 4), Point(0, 1)],
        [Point(0, 5), Point(0, 2)],
        [Point(0, 6), [Point(0, 2), Point(0, 3)]],
        [Point(0, 7), [Point(0, 2), Point(0, 3)]],
        [Point(0, 8), Point(0, 3)],
        [Point(0, 9), Point(0, 4)],
        [Point(0, 10), Point(0, 5)],
        [Point(0, 11), [Point(0, 5), Point(0, 6)]],
        [Point(0, 12), Point(0, 6)],
        [Point(0, 13), Point(0, 7)],
        [Point(0, 14), Point(0, 8)],
        [Point(0, 15), Point(0, 9)],
        [Point(0, 16), Point(0, 10)],
        [Point(0, 17), Point(0, 11)],
        [Point(0, 18), [Point(0, 11), Point(1, 0)]], # off end of first line
        [Point(1, 0), Point(1, 0)]
        [Point(1, 1), [Point(1, 0), Point(1, 1)]]
        [Point(1, 2), [Point(1, 0), Point(1, 1)]]
        [Point(1, 3), [Point(1, 0), Point(1, 1)]]
        [Point(1, 4), Point(1, 1)]
        [Point(1, 5), Point(1, 2)]
        [Point(1, 6), [Point(1, 2), Point(1, 2)]]
      ])

  describe "soft tabs", ->
    it "breaks leading whitespace into atomic units corresponding to the tab length", ->
      buffer = new TextBuffer(text: '          a\n     \n  \t    \t  ')
      displayLayer = buffer.addDisplayLayer(tabLength: 4, invisibles: {space: '•'})

      expect(displayLayer.getText()).toBe('••••••••••a\n•••••\n••  ••••    ••')

      expectTokens(displayLayer, [
        {text: '••••', close: [], open: ["invisible-character leading-whitespace"]},
        {text: '••••', close: ["invisible-character leading-whitespace"], open: ["invisible-character leading-whitespace"]},
        {text: '••', close: ["invisible-character leading-whitespace"], open: ["invisible-character leading-whitespace"]},
        {text: 'a', close: ["invisible-character leading-whitespace"], open: []},
        {text: '••••', close: [], open: ["invisible-character trailing-whitespace"]},
        {text: '•', close: ["invisible-character trailing-whitespace"], open: ["invisible-character trailing-whitespace"]},
        {text: '', close: ["invisible-character trailing-whitespace"], open: []},
        {text: '••', close: [], open: ["invisible-character trailing-whitespace"]},
        {text: '  ', close: ["invisible-character trailing-whitespace"], open: ["hard-tab trailing-whitespace"]},
        {text: '••••', close: ["hard-tab trailing-whitespace"], open: ["invisible-character trailing-whitespace"]},
        {text: '    ', close: ["invisible-character trailing-whitespace"], open: ["hard-tab trailing-whitespace"]},
        {text: '••', close: ["hard-tab trailing-whitespace"], open: ["invisible-character trailing-whitespace"]},
        {text: '', close: ["invisible-character trailing-whitespace"], open: []},
      ])

      expect(displayLayer.clipScreenPosition([0, 2])).toEqual [0, 0]
      expect(displayLayer.clipScreenPosition([0, 6])).toEqual [0, 4]
      expect(displayLayer.clipScreenPosition([0, 9])).toEqual [0, 9]
      expect(displayLayer.clipScreenPosition([2, 1])).toEqual [2, 1]
      expect(displayLayer.clipScreenPosition([2, 6])).toEqual [2, 4]
      expect(displayLayer.clipScreenPosition([2, 13])).toEqual [2, 13]

  describe "folds", ->
    it "allows single folds to be created and destroyed", ->
      buffer = new TextBuffer(text: SAMPLE_TEXT)
      displayLayer = buffer.addDisplayLayer()

      foldId = displayLayer.foldBufferRange([[4, 29], [7, 4]])

      expect(displayLayer.getText()).toBe '''
        var quicksort = function () {
          var sort = function(items) {
            if (items.length <= 1) return items;
            var pivot = items.shift(), current, left = [], right = [];
            while(items.length > 0) {⋯}
            return sort(left).concat(pivot).concat(sort(right));
          };

          return sort(Array.apply(this, arguments));
        };
      '''

      expect(displayLayer.clipScreenPosition([4, 29], clipDirection: 'forward')).toEqual([4, 29])
      expect(displayLayer.translateScreenPosition([4, 29], clipDirection: 'forward')).toEqual([4, 29])

      displayLayer.destroyFold(foldId)

      expect(displayLayer.getText()).toBe SAMPLE_TEXT

    it "allows folds that contain other folds to be created and destroyed", ->
      buffer = new TextBuffer(text: '''
        abcd
        efgh
        ijkl
        mnop
      ''')
      displayLayer = buffer.addDisplayLayer()

      displayLayer.foldBufferRange([[1, 1], [1, 3]])
      displayLayer.foldBufferRange([[2, 1], [2, 3]])
      outerFoldId = displayLayer.foldBufferRange([[0, 1], [3, 3]])
      expect(displayLayer.getText()).toBe 'a⋯p'

      displayLayer.destroyFold(outerFoldId)
      expect(displayLayer.getText()).toBe '''
        abcd
        e⋯h
        i⋯l
        mnop
      '''

    it "allows folds contained within other folds to be created and destroyed", ->
      buffer = new TextBuffer(text: '''
        abcd
        efgh
        ijkl
        mnop
      ''')
      displayLayer = buffer.addDisplayLayer()

      displayLayer.foldBufferRange([[0, 1], [3, 3]])
      innerFoldAId = displayLayer.foldBufferRange([[1, 1], [1, 3]])
      innerFoldBId = displayLayer.foldBufferRange([[2, 1], [2, 3]])
      expect(displayLayer.getText()).toBe 'a⋯p'

      displayLayer.destroyFold(innerFoldAId)
      expect(displayLayer.getText()).toBe 'a⋯p'

      displayLayer.destroyFold(innerFoldBId)
      expect(displayLayer.getText()).toBe 'a⋯p'

    it "allows multiple buffer lines to be collapsed to a single screen line by successive folds", ->
      buffer = new TextBuffer(text: '''
        abc
        def
        ghi
        j
      ''')
      displayLayer = buffer.addDisplayLayer()

      displayLayer.foldBufferRange([[0, 1], [1, 1]])
      displayLayer.foldBufferRange([[1, 2], [2, 1]])
      displayLayer.foldBufferRange([[2, 2], [3, 0]])

      expect(displayLayer.getText()).toBe 'a⋯e⋯h⋯j'

    it "unions folded ranges when folds overlap", ->
      buffer = new TextBuffer(text: '''
        abc
        def
        ghi
        j
      ''')
      displayLayer = buffer.addDisplayLayer()

      foldAId = displayLayer.foldBufferRange([[0, 1], [1, 2]])
      foldBId = displayLayer.foldBufferRange([[1, 1], [2, 2]])
      foldCId = displayLayer.foldBufferRange([[2, 1], [3, 0]])

      expect(displayLayer.getText()).toBe 'a⋯j'

      displayLayer.destroyFold(foldCId)
      expect(displayLayer.getText()).toBe 'a⋯i\nj'

      displayLayer.destroyFold(foldBId)
      expect(displayLayer.getText()).toBe 'a⋯f\nghi\nj'

    it "allows folds intersecting a buffer range to be destroyed", ->
      buffer = new TextBuffer(text: '''
        abc
        def
        ghi
        j
      ''')
      displayLayer = buffer.addDisplayLayer()

      displayLayer.foldBufferRange([[0, 1], [1, 2]])
      displayLayer.foldBufferRange([[1, 1], [2, 2]])
      displayLayer.foldBufferRange([[2, 1], [3, 0]])
      displayLayer.foldBufferRange([[2, 2], [3, 0]])

      expect(displayLayer.getText()).toBe 'a⋯j'

      verifyChangeEvent displayLayer, ->
        displayLayer.destroyFoldsIntersectingBufferRange([[1, 1], [2, 1]])

      expect(displayLayer.getText()).toBe 'abc\ndef\ngh⋯j'

    it "allows all folds to be destroyed", ->
      buffer = new TextBuffer(text: '''
        abc
        def
        ghi
        j
      ''')
      displayLayer = buffer.addDisplayLayer()

      displayLayer.foldBufferRange([[0, 1], [1, 2]])
      displayLayer.foldBufferRange([[1, 1], [2, 2]])
      displayLayer.foldBufferRange([[2, 1], [3, 0]])
      displayLayer.foldBufferRange([[2, 2], [3, 0]])

      expect(displayLayer.getText()).toBe 'a⋯j'

      verifyChangeEvent displayLayer, ->
        displayLayer.destroyAllFolds()

      expect(displayLayer.getText()).toBe 'abc\ndef\nghi\nj'

  describe "soft wraps", ->
    it "soft wraps the line at the rightmost word boundary at or preceding the softWrapColumn", ->
      buffer = new TextBuffer(text: 'abc def ghi jkl mno')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7)
      expect(displayLayer.getText()).toBe 'abc def \nghi jkl \nmno'

      buffer = new TextBuffer(text: 'abc defg hijkl mno')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7)
      expect(displayLayer.getText()).toBe 'abc \ndefg \nhijkl \nmno'

    it "soft wraps the line at the softWrapColumn if no word boundary precedes it", ->
      buffer = new TextBuffer(text: 'abcdefghijklmno')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7)
      expect(displayLayer.getText()).toBe 'abcdefg\nhijklmn\no'

    it "preserves the indent on wrapped segments of the line", ->
      buffer = new TextBuffer(text: '   abc de fghi jkl')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7)
      expect(displayLayer.getText()).toBe '   abc \n   de \n   fghi \n   jkl'

    it "ignores indents that are greater than or equal to the softWrapColumn", ->
      buffer = new TextBuffer(text: '       abcde fghijk')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7)
      expect(displayLayer.getText()).toBe '       \nabcde \nfghijk'

    it "honors the softWrapHangingIndent setting", ->
      buffer = new TextBuffer(text: 'abcdef ghi')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7, softWrapHangingIndent: 2)
      expect(displayLayer.getText()).toBe 'abcdef \n  ghi'

      buffer = new TextBuffer(text: '   abc de fghi jk')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7, softWrapHangingIndent: 2)
      expect(displayLayer.getText()).toBe '   abc \n     de \n     fg\n     hi \n     jk'

      buffer = new TextBuffer(text: '       abcde fghijk')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7, softWrapHangingIndent: 2)
      expect(displayLayer.getText()).toBe '       \n  abcde \n  fghij\n  k'

    ffit "translates points correctly on soft-wrapped lines", ->
      buffer = new TextBuffer(text: '   abc de fghi')
      displayLayer = buffer.addDisplayLayer(softWrapColumn: 7, softWrapHangingIndent: 2)
      expect(displayLayer.getText()).toBe '   abc\n     de\n     fg\n     hi'

      expectPositionTranslations(displayLayer, [
        [Point(0, 0), Point(0, 0)],
        [Point(0, 1), Point(0, 1)],
        [Point(0, 2), Point(0, 2)],
        [Point(0, 3), Point(0, 3)],
        [Point(0, 4), Point(0, 4)],
        [Point(0, 5), Point(0, 5)],
        [Point(0, 6), Point(0, 6)],
        [Point(0, 7), [Point(0, 6), Point(0, 7)]],
        [Point(0, 8), [Point(0, 6), Point(0, 7)]],
        [Point(1, 0), [Point(0, 6), Point(0, 7)]],
        [Point(1, 1), [Point(0, 6), Point(0, 7)]],
        [Point(1, 2), [Point(0, 6), Point(0, 7)]],
        [Point(1, 3), [Point(0, 6), Point(0, 7)]],
        [Point(1, 4), [Point(0, 6), Point(0, 7)]],
        [Point(1, 5), Point(0, 7)],
        [Point(1, 6), Point(0, 8)],
        [Point(1, 7), Point(0, 9)],
        [Point(1, 8), [Point(0, 9), Point(0, 10)]],
        [Point(1, 9), [Point(0, 9), Point(0, 10)]],
        [Point(2, 0), [Point(0, 9), Point(0, 10)]],
        [Point(2, 1), [Point(0, 9), Point(0, 10)]],
        [Point(2, 2), [Point(0, 9), Point(0, 10)]],
        [Point(2, 3), [Point(0, 9), Point(0, 10)]],
        [Point(2, 4), [Point(0, 9), Point(0, 10)]],
        [Point(2, 5), Point(0, 10)],
        [Point(2, 6), Point(0, 11)],
        [Point(2, 7), [Point(0, 12), Point(0, 12)]],
        [Point(2, 8), [Point(0, 12), Point(0, 12)]],
        [Point(3, 0), [Point(0, 12), Point(0, 12)]],
        [Point(3, 1), [Point(0, 12), Point(0, 12)]],
        [Point(3, 2), [Point(0, 12), Point(0, 12)]],
        [Point(3, 3), [Point(0, 12), Point(0, 12)]],
        [Point(3, 4), [Point(0, 12), Point(0, 12)]],
        [Point(3, 5), Point(0, 12)],
        [Point(3, 6), Point(0, 13)],
        [Point(3, 7), Point(0, 14)]
      ])

  describe "invisibles", ->
    it "replaces leading whitespaces with the corresponding invisible character, appropriately decorated", ->
      buffer = new TextBuffer(text: """
        az
          b c
           d
         \t e
      """)

      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {space: '•'}})

      expect(displayLayer.getText()).toBe("""
        az
        ••b c
        •••d
        •   •e
      """)

      expectTokens(displayLayer, [
        {text: 'az', close: [], open: []},
        {text: '••', close: [], open: ["invisible-character leading-whitespace"]},
        {text: 'b c', close: ["invisible-character leading-whitespace"], open: []},
        {text: '•••', close: [], open: ["invisible-character leading-whitespace"]},
        {text: 'd', close: ["invisible-character leading-whitespace"], open: []},
        {text: '•', close: [], open: ["invisible-character leading-whitespace"]},
        {text: '   ', close: ["invisible-character leading-whitespace"], open: ["hard-tab leading-whitespace"]},
        {text: '•', close: ["hard-tab leading-whitespace"], open: ["invisible-character leading-whitespace"]},
        {text: 'e', close: ["invisible-character leading-whitespace"], open: []},
      ])

    it "replaces trailing whitespaces with the corresponding invisible character, appropriately decorated", ->
      buffer = new TextBuffer("abcd\n       \nefgh   jkl\nmno  pqr   \nst  uvw  \t  ")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {space: '•'}})

      expect(displayLayer.getText()).toEqual("abcd\n•••••••\nefgh   jkl\nmno  pqr•••\nst  uvw••   ••")
      expectTokens(displayLayer, [
        {text: 'abcd', close: [], open: []},
        {text: '••••', close: [], open: ["invisible-character trailing-whitespace"]},
        {text: '•••', close: ["invisible-character trailing-whitespace"], open: ["invisible-character trailing-whitespace"]},
        {text: '', close: ["invisible-character trailing-whitespace"], open: []},
        {text: 'efgh   jkl', close: [], open: []},
        {text: 'mno  pqr', close: [], open: []},
        {text: '•••', close: [], open: ["invisible-character trailing-whitespace"]},
        {text: '', close: ["invisible-character trailing-whitespace"], open: []},
        {text: 'st  uvw', close: [], open: []},
        {text: '••', close: [], open: ["invisible-character trailing-whitespace"]},
        {text: '   ', close: ["invisible-character trailing-whitespace"], open: ["hard-tab trailing-whitespace"]},
        {text: '••', close: ["hard-tab trailing-whitespace"], open: ["invisible-character trailing-whitespace"]},
        {text: '', close: ["invisible-character trailing-whitespace"], open: []},
      ])

    it "decorates hard tabs, leading whitespace, and trailing whitespace, even when no invisible characters are specified", ->
      buffer = new TextBuffer(" \t a\tb \t \n  ")
      displayLayer = buffer.addDisplayLayer({tabLength: 4})

      expect(displayLayer.getText()).toEqual("     a  b    \n  ")
      expectTokens(displayLayer, [
        {text: ' ', close: [], open: ["leading-whitespace"]},
        {text: '   ', close: ["leading-whitespace"], open: ["hard-tab leading-whitespace"]},
        {text: ' ', close: ["hard-tab leading-whitespace"], open: ["leading-whitespace"]},
        {text: 'a', close: ["leading-whitespace"], open: []},
        {text: '  ', close: [], open: ["hard-tab"]},
        {text: 'b', close: ["hard-tab"], open: []},
        {text: ' ', close: [], open: ["trailing-whitespace"]},
        {text: '  ', close: ["trailing-whitespace"], open: ["hard-tab trailing-whitespace"]},
        {text: ' ', close: ["hard-tab trailing-whitespace"], open: ["trailing-whitespace"]},
        {text: '', close: ["trailing-whitespace"], open: []},
        {text: '  ', close: [], open: ["trailing-whitespace"]},
        {text: '', close: ["trailing-whitespace"], open: []},
      ])

    it "renders invisibles correctly when leading or trailing whitespace intersects folds", ->
      buffer = new TextBuffer("    a    \n    b\nc    \nd")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {space: '•'}})
      displayLayer.foldBufferRange([[0, 2], [0, 7]])
      displayLayer.foldBufferRange([[1, 2], [2, 2]])
      displayLayer.foldBufferRange([[2, 4], [3, 0]])
      expect(displayLayer.getText()).toBe("••⋯••\n••⋯••⋯d")

      expectTokens(displayLayer, [
        {text: '••', close: [], open: ["invisible-character leading-whitespace"]},
        {text: '⋯', close: ["invisible-character leading-whitespace"], open: ["fold-marker"]},
        {text: '••', close: ["fold-marker"], open: ["invisible-character trailing-whitespace"]},
        {text: '', close: ["invisible-character trailing-whitespace"], open: []},
        {text: '••', close: [], open: ["invisible-character leading-whitespace"]},
        {text: '⋯', close: ["invisible-character leading-whitespace"], open: ["fold-marker"]},
        {text: '••', close: ["fold-marker"], open: ["invisible-character trailing-whitespace"]},
        {text: '⋯', close: ["invisible-character trailing-whitespace"], open: ["fold-marker"]},
        {text: 'd', close: ["fold-marker"], open: []},
      ])

    it "renders tab invisibles, appropriately decorated", ->
      buffer = new TextBuffer(text: "a\tb\t\n \t d  \t  ")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {tab: '»', space: '•'}})

      expect(displayLayer.getText()).toBe("a»  b»  \n•»  •d••»   ••")
      expectTokens(displayLayer, [
        {text: 'a', close: [], open: []},
        {text: '»  ', close: [], open: ["invisible-character hard-tab"]},
        {text: 'b', close: ["invisible-character hard-tab"], open: []},
        {text: '»  ', close: [], open: ["invisible-character hard-tab trailing-whitespace"]},
        {text: '', close: ["invisible-character hard-tab trailing-whitespace"], open: []},
        {text: '•', close: [], open: ["invisible-character leading-whitespace"]},
        {text: '»  ', close: ["invisible-character leading-whitespace"], open: ["invisible-character hard-tab leading-whitespace"]},
        {text: '•', close: ["invisible-character hard-tab leading-whitespace"], open: ["invisible-character leading-whitespace"]},
        {text: 'd', close: ["invisible-character leading-whitespace"], open: []},
        {text: '••', close: [], open: ["invisible-character trailing-whitespace"]},
        {text: '»   ', close: ["invisible-character trailing-whitespace"], open: ["invisible-character hard-tab trailing-whitespace"]},
        {text: '••', close: ["invisible-character hard-tab trailing-whitespace"], open: ["invisible-character trailing-whitespace"]},
        {text: '', close: ["invisible-character trailing-whitespace"], open: []},
      ])

    it "renders end of line invisibles, appropriately decorated", ->
      buffer = new TextBuffer(text: "a\nb\n\nd e f\r\ngh\rij\n\r\n")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {cr: '¤', eol: '¬'}})

      expect(displayLayer.getText()).toBe("a¬\nb¬\n¬\nd e f¤¬\ngh¤\nij¬\n¤¬\n")
      expectTokens(displayLayer, [
        {text: 'a', close: [], open: []},
        {text: '¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: 'b', close: [], open: []},
        {text: '¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: '¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: 'd e f', close: [], open: []},
        {text: '¤¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: 'gh', close: [], open: []},
        {text: '¤', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: 'ij', close: [], open: []},
        {text: '¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: '¤¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: '', close: [], open: []},
      ])

    it "does not clip positions within runs of invisible characters", ->
      buffer = new TextBuffer(text: "   a")
      displayLayer = buffer.addDisplayLayer({invisibles: {space: '•'}})
      expect(displayLayer.clipScreenPosition(Point(0, 2))).toEqual(Point(0, 2))

  describe "indent guides", ->
    it "decorates tab-stop-aligned regions of leading whitespace with indent guides", ->
      buffer = new TextBuffer(text: "         a      \t  \n  \t\t b\n  \t\t")
      displayLayer = buffer.addDisplayLayer({showIndentGuides: true, tabLength: 4})

      expect(displayLayer.getText()).toBe("         a            \n         b\n        ")
      expectTokens(displayLayer, [
        {text: '    ', close: [], open: ["leading-whitespace indent-guide"]},
        {text: '    ', close: ["leading-whitespace indent-guide"], open: ["leading-whitespace indent-guide"]},
        {text: ' ', close: ["leading-whitespace indent-guide"], open: ["leading-whitespace indent-guide"]},
        {text: 'a', close: ["leading-whitespace indent-guide"], open: []},
        {text: '      ', close: [], open: ["trailing-whitespace"]},
        {text: '    ', close: ["trailing-whitespace"], open: ["hard-tab trailing-whitespace"]},
        {text: '  ', close: ["hard-tab trailing-whitespace"], open: ["trailing-whitespace"]},
        {text: '', close: ["trailing-whitespace"], open: []},
        {text: '  ', close: [], open: ["leading-whitespace indent-guide"]},
        {text: '  ', close: ["leading-whitespace indent-guide"], open: ["hard-tab leading-whitespace"]},
        {text: '    ', close: ["hard-tab leading-whitespace"], open: ["hard-tab leading-whitespace indent-guide"]},
        {text: ' ', close: ["hard-tab leading-whitespace indent-guide"], open: ["leading-whitespace indent-guide"]},
        {text: 'b', close: ["leading-whitespace indent-guide"], open: []},
        {text: '  ', close: [], open: ["trailing-whitespace indent-guide"]},
        {text: '  ', close: ["trailing-whitespace indent-guide"], open: ["hard-tab trailing-whitespace"]},
        {text: '    ', close: ["hard-tab trailing-whitespace"], open: ["hard-tab trailing-whitespace indent-guide"]},
        {text: '', close: ["hard-tab trailing-whitespace indent-guide"], open: []},
      ])

    it "decorates empty lines with the appropriate number of indent guides", ->
      buffer = new TextBuffer(text: "\n\n          a\n\n     b\n\n\n")
      displayLayer = buffer.addDisplayLayer({showIndentGuides: true, tabLength: 4, invisibles: {eol: '¬'}})

      expect(displayLayer.getText()).toBe("¬       \n¬       \n          a¬\n¬       \n     b¬\n¬   \n¬   \n    ")
      expectTokens(displayLayer, [
        {text: '¬', close: [], open: ["invisible-character eol indent-guide"]},
        {text: '   ', close: ["invisible-character eol indent-guide"], open: []},
        {text: '    ', close: [], open: ["indent-guide"]},
        {text: '', close: ["indent-guide"], open: []},
        {text: '¬', close: [], open: ["invisible-character eol indent-guide"]},
        {text: '   ', close: ["invisible-character eol indent-guide"], open: []},
        {text: '    ', close: [], open: ["indent-guide"]},
        {text: '', close: ["indent-guide"], open: []},
        {text: '    ', close: [], open: ["leading-whitespace indent-guide"]},
        {text: '    ', close: ["leading-whitespace indent-guide"], open: ["leading-whitespace indent-guide"]},
        {text: '  ', close: ["leading-whitespace indent-guide"], open: ["leading-whitespace indent-guide"]},
        {text: 'a', close: ["leading-whitespace indent-guide"], open: []},
        {text: '¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: '¬', close: [], open: ["invisible-character eol indent-guide"]},
        {text: '   ', close: ["invisible-character eol indent-guide"], open: []},
        {text: '    ', close: [], open: ["indent-guide"]},
        {text: '', close: ["indent-guide"], open: []},
        {text: '    ', close: [], open: ["leading-whitespace indent-guide"]},
        {text: ' ', close: ["leading-whitespace indent-guide"], open: ["leading-whitespace indent-guide"]},
        {text: 'b', close: ["leading-whitespace indent-guide"], open: []},
        {text: '¬', close: [], open: ["invisible-character eol"]},
        {text: '', close: ["invisible-character eol"], open: []},
        {text: '¬', close: [], open: ["invisible-character eol indent-guide"]},
        {text: '   ', close: ["invisible-character eol indent-guide"], open: []},
        {text: '¬', close: [], open: ["invisible-character eol indent-guide"]},
        {text: '   ', close: ["invisible-character eol indent-guide"], open: []},
        {text: '    ', close: [], open: ["indent-guide"]},
        {text: '', close: ["indent-guide"], open: []},
      ])
      # does not translate buffer positions to the end of inserted indent guides
      for i in [0..20]
        expect(displayLayer.translateBufferPosition([0, i])).toEqual([0, 0])
        expect(displayLayer.clipScreenPosition([0, i])).toEqual([0, 0])

  describe "text decorations", ->
    it "exposes open and close tags from the text decoration layer in the token iterator", ->
      buffer = new TextBuffer(text: """
        abcde
        fghij
        klmno
      """)

      displayLayer = buffer.addDisplayLayer()
      displayLayer.setTextDecorationLayer(new TestDecorationLayer([
        ['aa', [[0, 1], [0, 4]]]
        ['ab', [[0, 2], [1, 2]]]
        ['ac', [[0, 3], [1, 2]]]
        ['ad', [[1, 3], [2, 0]]]
        ['ae', [[2, 3], [2, 5]]]
      ]))

      expectTokens(displayLayer, [
        {text: 'a', close: [], open: []},
        {text: 'b', close: [], open: ['aa']},
        {text: 'c', close: [], open: ['ab']},
        {text: 'd', close: [], open: ['ac']},
        {text: 'e', close: ['ac', 'ab', 'aa'], open: ['ab', 'ac']},
        {text: '', close: ['ac', 'ab'], open: []},
        {text: 'fg', close: [], open: ['ab', 'ac']},
        {text: 'h', close: ['ac', 'ab'], open: []},
        {text: 'ij', close: [], open: ['ad']},
        {text: '', close: ['ad'], open: []},
        {text: 'klm', close: [], open: []},
        {text: 'no', close: [], open: ['ae']},
        {text: '', close: ['ae'], open: []}
      ])

    it "truncates decoration tags at fold boundaries", ->
      buffer = new TextBuffer(text: """
        abcde
        fghij
        klmno
      """)

      displayLayer = buffer.addDisplayLayer()
      displayLayer.foldBufferRange([[0, 3], [2, 2]])
      displayLayer.setTextDecorationLayer(new TestDecorationLayer([
        ['preceding-fold', [[0, 1], [0, 2]]]
        ['ending-at-fold-start', [[0, 1], [0, 3]]]
        ['overlapping-fold-start', [[0, 1], [1, 1]]]
        ['inside-fold', [[0, 4], [1, 4]]]
        ['overlapping-fold-end', [[1, 4], [2, 4]]]
        ['starting-at-fold-end', [[2, 2], [2, 4]]]
        ['following-fold', [[2, 4], [2, 5]]]
        ['surrounding-fold', [[0, 1], [2, 5]]]
      ]))

      expectTokens(displayLayer, [
        {text: 'a', close: [], open: []},
        {text: 'b', close: [], open: ['preceding-fold', 'ending-at-fold-start', 'overlapping-fold-start', 'surrounding-fold']},
        {text: 'c', close: ['surrounding-fold', 'overlapping-fold-start', 'ending-at-fold-start', 'preceding-fold'], open: ['ending-at-fold-start', 'overlapping-fold-start', 'surrounding-fold']},
        {text: '⋯', close: ['surrounding-fold', 'overlapping-fold-start', 'ending-at-fold-start'], open: ['fold-marker']},
        {text: 'mn', close: ['fold-marker'], open: ['surrounding-fold', 'overlapping-fold-end', 'starting-at-fold-end']},
        {text: 'o', close: ['starting-at-fold-end', 'overlapping-fold-end'], open: ['following-fold']},
        {text: '', close: ['following-fold', 'surrounding-fold'], open: []}
      ])

    it "emits update events from the display layer when text decoration ranges are invalidated", ->
      buffer = new TextBuffer(text: """
        abc
        def
        ghi
        jkl
        mno
      """)
      displayLayer = buffer.addDisplayLayer()
      displayLayer.foldBufferRange([[1, 3], [2, 0]])
      decorationLayer = new TestDecorationLayer([])
      displayLayer.setTextDecorationLayer(decorationLayer)

      allChanges = []
      displayLayer.onDidChangeSync((changes) -> allChanges.push(changes...))

      decorationLayer.emitInvalidateRangeEvent([[2, 1], [3, 2]])
      expect(allChanges).toEqual [{start: Point(1, 5), oldExtent: Point(1, 2), newExtent: Point(1, 2)}]

    it "throws an error if the text decoration iterator reports a boundary beyond the end of a line", ->
      buffer = new TextBuffer(text: """
        abc
        \tdef
      """)
      displayLayer = buffer.addDisplayLayer(tabLength: 2)
      decorationLayer = new TestDecorationLayer([
        ['a', [[0, 1], [0, 10]]]
      ])
      displayLayer.setTextDecorationLayer(decorationLayer)

      exception = null
      try
        getTokenLines(displayLayer)
      catch e
        exception = e

      expect(e.message).toMatch(/Invalid text decoration iterator position/)

  now = Date.now()
  for i in [0...100] by 1
    do ->
      seed = now + i
      it "updates the displayed text correctly when the underlying buffer changes: #{seed}", ->
        random = new Random(seed)
        buffer = new TextBuffer(text: buildRandomLines(random, 10))
        invisibles = {}
        invisibles.space = '•' if random(2) > 0
        invisibles.eol = '¬' if random(2) > 0
        invisibles.cr = '¤' if random(2) > 0
        showIndentGuides = Boolean(random(2))
        displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles, showIndentGuides})
        textDecorationLayer = new TestDecorationLayer([], buffer, random)
        displayLayer.setTextDecorationLayer(textDecorationLayer)

        foldIds = []
        screenLinesById = new Map

        for j in [0...5] by 1
          k = random(10)
          if k < 2
            createRandomFold(random, displayLayer, foldIds)
          else if k < 4 and foldIds.length > 0
            destroyRandomFold(random, displayLayer, foldIds)
          else
            performRandomChange(random, buffer, displayLayer)

          # incrementally-updated text matches freshly computed text
          expectedDisplayLayer = buffer.addDisplayLayer({foldsMarkerLayer: displayLayer.foldsMarkerLayer.copy(), tabLength: 4, invisibles, showIndentGuides})
          expect(JSON.stringify(displayLayer.getText())).toBe(JSON.stringify(expectedDisplayLayer.getText()))

          verifyPositionTranslations(displayLayer, expectedDisplayLayer)
          verifyTokens(displayLayer)
          verifyRightmostScreenPosition(displayLayer)
          verifyScreenLineIds(displayLayer, screenLinesById)

          expectedDisplayLayer.destroy()

performRandomChange = (random, buffer, displayLayer) ->
  tries = 10
  range = getRandomRange(random, buffer)
  while displayLayer.foldsMarkerLayer.findMarkers(intersectsRange: range).length > 0
    range = getRandomRange(random, buffer)
    return if --tries is 0

  verifyChangeEvent displayLayer, ->
    text = buildRandomLines(random, 4)
    buffer.setTextInRange(range, text)

createRandomFold = (random, displayLayer, foldIds) ->
  verifyChangeEvent displayLayer, ->
    bufferRange = getRandomRange(random, displayLayer.buffer)
    foldId = displayLayer.foldBufferRange(bufferRange)
    foldIds.push(foldId)

destroyRandomFold = (random, displayLayer, foldIds) ->
  verifyChangeEvent displayLayer, ->
    [foldId] = foldIds.splice(random(foldIds.length - 1), 1)
    displayLayer.destroyFold(foldId)

verifyChangeEvent = (displayLayer, fn) ->
  previousTokenLines = getTokenLines(displayLayer)
  lastChanges = null
  disposable = displayLayer.onDidChangeSync (changes) -> lastChanges = changes

  fn()
  disposable.dispose()
  if lastChanges?
    expectedTokenLines = getTokenLines(displayLayer)
    updateTokenLines(previousTokenLines, displayLayer, lastChanges)

    # {diffString} = require 'json-diff'
    # diff = diffString(expectedTokenLines, previousTokenLines, color: false)
    # console.log diff
    # console.log previousTokenLines
    # console.log expectedTokenLines
    expect(previousTokenLines).toEqual(expectedTokenLines)
  else
    expect(getTokenLines(displayLayer)).toEqual(previousTokenLines)

verifyTokens = (displayLayer) ->
  containingTags = []

  for tokens in getTokenLines(displayLayer)
    for {closeTags, openTags, text} in tokens
      for tag in closeTags
        mostRecentOpenTag = containingTags.pop()
        expect(mostRecentOpenTag).toBe(tag)
      containingTags.push(openTags...)

    expect(containingTags).toEqual([])

  expect(containingTags).toEqual([])

verifyPositionTranslations = (actualDisplayLayer, expectedDisplayLayer) ->
  {buffer} = actualDisplayLayer

  bufferLines = buffer.getText().split('\n')
  screenLines = actualDisplayLayer.getText().split('\n')

  for bufferLine, bufferRow in bufferLines
    for character, bufferColumn in bufferLine
      actualPosition = actualDisplayLayer.translateBufferPosition(Point(bufferRow, bufferColumn))
      expectedPosition = expectedDisplayLayer.translateBufferPosition(Point(bufferRow, bufferColumn))
      expect(actualPosition).toEqual(expectedPosition)

  for screenLine, screenRow in screenLines
    for character, screenColumn in screenLine
      actualPosition = actualDisplayLayer.translateScreenPosition(Point(screenRow, screenColumn))
      expectedPosition = expectedDisplayLayer.translateScreenPosition(Point(screenRow, screenColumn))
      expect(actualPosition).toEqual(expectedPosition)

verifyRightmostScreenPosition = (displayLayer) ->
  screenLines = displayLayer.getText().split('\n')
  lastScreenRow = screenLines.length - 1

  maxLineLength = -1
  longestScreenRows = new Set
  for screenLine, row in screenLines
    bufferRow = displayLayer.translateScreenPosition({row: row, column: 0}).row
    bufferLine = displayLayer.buffer.lineForRow(bufferRow)

    expect(displayLayer.lineLengthForScreenRow(row)).toBe(screenLine.length)

    if screenLine.length > maxLineLength
      longestScreenRows.clear()
      maxLineLength = screenLine.length

    if screenLine.length >= maxLineLength
      longestScreenRows.add(row)

  rightmostScreenPosition = displayLayer.getRightmostScreenPosition()
  expect(rightmostScreenPosition.column).toBe(maxLineLength)
  expect(longestScreenRows.has(rightmostScreenPosition.row)).toBe(true)

verifyScreenLineIds = (displayLayer, screenLinesById) ->
  for screenLine in displayLayer.getScreenLines()
    if screenLinesById.has(screenLine.id)
      expect(screenLinesById.get(screenLine.id)).toEqual(screenLine)
    else
      screenLinesById.set(screenLine.id, screenLine)

buildRandomLines = (random, maxLines) ->
  lines = []
  for i in [0...random(maxLines)] by 1
    lines.push(buildRandomLine(random))
  lines.join('\n')

buildRandomLine = (random) ->
  line = []
  for i in [0...random(5)] by 1
    n = random(10)
    if n < 2
      line.push('\t')
    else if n < 4
      line.push(' ')
    else
      line.push(' ') if line.length > 0 and not /\s/.test(line[line.length - 1])
      line.push(WORDS[random(WORDS.length)])
  line.join('')

getRandomRange = (random, buffer) ->
  Range(getRandomPoint(random, buffer), getRandomPoint(random, buffer))

getRandomPoint = (random, buffer) ->
  row = random(buffer.getLineCount())
  column = random(buffer.lineForRow(row).length + 1)
  Point(row, column)

substringForRange = (text, range) ->
  startIndex = characterIndexForPoint(text, range.start)
  endIndex = characterIndexForPoint(text, range.end)
  text.substring(startIndex, endIndex)

expectPositionTranslations = (displayLayer, tranlations) ->
  for [screenPosition, bufferPositions] in tranlations
    if Array.isArray(bufferPositions)
      [backwardBufferPosition, forwardBufferPosition] = bufferPositions
      expect(displayLayer.translateScreenPosition(screenPosition, clipDirection: 'backward')).toEqual(backwardBufferPosition)
      expect(displayLayer.translateScreenPosition(screenPosition, clipDirection: 'forward')).toEqual(forwardBufferPosition)
      expect(displayLayer.clipScreenPosition(screenPosition, clipDirection: 'backward')).toEqual(displayLayer.translateBufferPosition(backwardBufferPosition, clipDirection: 'backward'))
      expect(displayLayer.clipScreenPosition(screenPosition, clipDirection: 'forward')).toEqual(displayLayer.translateBufferPosition(forwardBufferPosition, clipDirection: 'forward'))
    else
      bufferPosition = bufferPositions
      expect(displayLayer.translateScreenPosition(screenPosition)).toEqual(bufferPosition)
      expect(displayLayer.translateBufferPosition(bufferPosition)).toEqual(screenPosition)

expectTokens = (displayLayer, expectedTokens) ->
  tokenLines = getTokenLines(displayLayer)
  for tokens, screenRow in tokenLines
    screenColumn = 0
    for token in tokens
      throw new Error("There are more tokens than expected.") if expectedTokens.length is 0
      {text, open, close} = expectedTokens.shift()
      expect(token.text).toEqual(text)
      expect(token.closeTags).toEqual(close, "Close tags of token with start position #{Point(screenRow, screenColumn)}")
      expect(token.openTags).toEqual(open, "Open tags of token with start position: #{Point(screenRow, screenColumn)}")
      screenColumn += token.text.length

getTokenLines = (displayLayer, startRow=0, endRow=displayLayer.getScreenLineCount()) ->
  tokenLines = []
  for screenLine in displayLayer.getScreenLines(startRow, endRow)
    tokenLines.push(screenLine.tokens)
  tokenLines

updateTokenLines = (tokenLines, displayLayer, changes) ->
  for {start, oldExtent, newExtent} in changes
    tokenLines.splice(start.row, oldExtent.row, getTokenLines(displayLayer, start.row, start.row + newExtent.row)...)

logTokens = (displayLayer) ->
  s = 'expectTokens(displayLayer, [\n'
  for tokens in getTokenLines(displayLayer)
    for {text, closeTags, openTags} in tokens
      s += "  {text: '#{text}', close: #{JSON.stringify(closeTags)}, open: #{JSON.stringify(openTags)}},\n"
  s += '])'
  console.log s
