Random = require 'random-seed'
TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'
{characterIndexForPoint, isEqual: isEqualPoint} = require '../src/point-helpers'
WORDS = require './helpers/words'
SAMPLE_TEXT = require './helpers/sample-text'
{currentSpecFailed} = require "./spec-helper"
TestDecorationLayer = require './helpers/test-decoration-layer'

describe "DisplayLayer", ->
  describe "hard tabs", ->
    it "expands hard tabs to their tab stops", ->
      buffer = new TextBuffer(text: '\ta\tbc\tdef\tg\n\th')
      displayLayer = buffer.addDisplayLayer(tabLength: 4)

      expect(displayLayer.getText()).toBe('    a   bc  def g\n    h')
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
        [Point(0, 18), [Point(0, 11), Point(1, 0)]],
        [Point(1, 0), Point(1, 0)]
        [Point(1, 1), [Point(1, 0), Point(1, 1)]]
        [Point(1, 2), [Point(1, 0), Point(1, 1)]]
        [Point(1, 3), [Point(1, 0), Point(1, 1)]]
        [Point(1, 4), Point(1, 1)]
        [Point(1, 5), Point(1, 2)]
        [Point(1, 6), [Point(1, 2), Point(1, 2)]]
      ])

      verifyTokenIterator(displayLayer)

  describe "soft tabs", ->
    it "breaks leading whitespace into atomic units corresponding to the tab length", ->
      buffer = new TextBuffer(text: '          a\n     \n  \t    \t  ')
      displayLayer = buffer.addDisplayLayer(tabLength: 4, invisibles: {space: '•'})

      expect(displayLayer.getText()).toBe('••••••••••a\n•••••\n••  ••••    ••')

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
        {start: [0, 0], end: [0, 2], close: [], open: []}
        {start: [1, 0], end: [1, 2], close: [], open: ['invisible-character leading-whitespace']}
        {start: [1, 2], end: [1, 5], close: ['invisible-character leading-whitespace'], open: []}
        {start: [2, 0], end: [2, 3], close: [], open: ['invisible-character leading-whitespace']}
        {start: [2, 3], end: [2, 4], close: ['invisible-character leading-whitespace'], open: []}
        {start: [3, 0], end: [3, 1], close: [], open: ['invisible-character leading-whitespace']}
        {start: [3, 1], end: [3, 4], close: ['invisible-character leading-whitespace'], open: ['hard-tab leading-whitespace']}
        {start: [3, 4], end: [3, 5], close: ['hard-tab leading-whitespace'], open: ['invisible-character leading-whitespace']}
        {start: [3, 5], end: [3, 6], close: ['invisible-character leading-whitespace'], open: []}
      ])

      tokenIterator = displayLayer.buildTokenIterator()
      tokenIterator.seekToScreenRow(1)
      expect(tokenIterator.getCloseTags()).toEqual []
      expect(tokenIterator.getOpenTags()).toEqual ['invisible-character leading-whitespace']
      tokenIterator.seekToScreenRow(2)
      expect(tokenIterator.getCloseTags()).toEqual []
      expect(tokenIterator.getOpenTags()).toEqual ['invisible-character leading-whitespace']
      tokenIterator.seekToScreenRow(3)
      expect(tokenIterator.getCloseTags()).toEqual []
      expect(tokenIterator.getOpenTags()).toEqual ['invisible-character leading-whitespace']

    it "replaces trailing whitespaces with the corresponding invisible character, appropriately decorated", ->
      buffer = new TextBuffer("abcd\n       \nefgh   jkl\nmno  pqr   \nst  uvw  \t  ")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {space: '•'}})
      expect(displayLayer.getText()).toEqual("abcd\n•••••••\nefgh   jkl\nmno  pqr•••\nst  uvw••   ••")

      expectTokens(displayLayer, [
        {start: [0, 0], end: [0, 4], close: [], open: []}
        {start: [1, 0], end: [1, 4], close: [], open: ['invisible-character trailing-whitespace']}
        {start: [1, 4], end: [1, 7], close: ['invisible-character trailing-whitespace'], open: ['invisible-character trailing-whitespace']}
        {start: [1, 7], end: [1, 7], close: ['invisible-character trailing-whitespace'], open: []}
        {start: [2, 0], end: [2, 10], close: [], open: []}
        {start: [3, 0], end: [3, 8], close: [], open: []}
        {start: [3, 8], end: [3, 11], close: [], open: ['invisible-character trailing-whitespace']}
        {start: [3, 11], end: [3, 11], close: ['invisible-character trailing-whitespace'], open: []}
        {start: [4, 0], end: [4, 7], close: [], open: []}
        {start: [4, 7], end: [4, 9], close: [], open: ['invisible-character trailing-whitespace']}
        {start: [4, 9], end: [4, 12], close: ['invisible-character trailing-whitespace'], open: ['hard-tab trailing-whitespace']}
        {start: [4, 12], end: [4, 14], close: ['hard-tab trailing-whitespace'], open: ['invisible-character trailing-whitespace']}
        {start: [4, 14], end: [4, 14], close: ['invisible-character trailing-whitespace'], open: []}
      ])

    it "decorates hard tabs, leading whitespace, and trailing whitespace, even when no invisible characters are specified", ->
      buffer = new TextBuffer(" \t a\tb \t \n  ")
      displayLayer = buffer.addDisplayLayer({tabLength: 4})
      expect(displayLayer.getText()).toEqual("     a  b    \n  ")
      expectTokens(displayLayer, [
        {start: [0, 0], end: [0, 1], close: [], open: ['leading-whitespace']}
        {start: [0, 1], end: [0, 4], close: ['leading-whitespace'], open: ['hard-tab leading-whitespace']}
        {start: [0, 4], end: [0, 5], close: ['hard-tab leading-whitespace'], open: ['leading-whitespace']}
        {start: [0, 5], end: [0, 6], close: ['leading-whitespace'], open: []}
        {start: [0, 6], end: [0, 8], close: [], open: ['hard-tab']}
        {start: [0, 8], end: [0, 9], close: ['hard-tab'], open: []}
        {start: [0, 9], end: [0, 10], close: [], open: ['trailing-whitespace']}
        {start: [0, 10], end: [0, 12], close: ['trailing-whitespace'], open: ['hard-tab trailing-whitespace']}
        {start: [0, 12], end: [0, 13], close: ['hard-tab trailing-whitespace'], open: ['trailing-whitespace']}
        {start: [0, 13], end: [0, 13], close: ['trailing-whitespace'], open: []}
        {start: [1, 0], end: [1, 2], close: [], open: ['trailing-whitespace']}
        {start: [1, 2], end: [1, 2], close: ['trailing-whitespace'], open: []}
      ])

    it "renders invisibles correctly when leading or trailing whitespace intersects folds", ->
      buffer = new TextBuffer("    a    \n    b\nc    \nd")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {space: '•'}})
      displayLayer.foldBufferRange([[0, 2], [0, 7]])
      displayLayer.foldBufferRange([[1, 2], [2, 2]])
      displayLayer.foldBufferRange([[2, 4], [3, 0]])
      expect(displayLayer.getText()).toBe("••⋯••\n••⋯••⋯d")

    it "renders tab invisibles, appropriately decorated", ->
      buffer = new TextBuffer(text: "a\tb\t\n \t d  \t  ")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {tab: '»', space: '•'}})
      expect(displayLayer.getText()).toBe("a»  b»  \n•»  •d••»   ••")

      expectTokens(displayLayer, [
        {start: [0, 0], end: [0, 1], close: [], open: []}
        {start: [0, 1], end: [0, 4], close: [], open: ['invisible-character hard-tab']}
        {start: [0, 4], end: [0, 5], close: ['invisible-character hard-tab'], open: []}
        {start: [0, 5], end: [0, 8], close: [], open: ['invisible-character hard-tab trailing-whitespace']}
        {start: [0, 8], end: [0, 8], close: ['invisible-character hard-tab trailing-whitespace'], open: []}
        {start: [1, 0], end: [1, 1], close: [], open: ['invisible-character leading-whitespace']}
        {start: [1, 1], end: [1, 4], close: ['invisible-character leading-whitespace'], open: ['invisible-character hard-tab leading-whitespace']}
        {start: [1, 4], end: [1, 5], close: ['invisible-character hard-tab leading-whitespace'], open: ['invisible-character leading-whitespace']}
        {start: [1, 5], end: [1, 6], close: ['invisible-character leading-whitespace'], open: []}
        {start: [1, 6], end: [1, 8], close: [], open: ['invisible-character trailing-whitespace']}
        {start: [1, 8], end: [1, 12], close: ['invisible-character trailing-whitespace'], open: ['invisible-character hard-tab trailing-whitespace']}
        {start: [1, 12], end: [1, 14], close: ['invisible-character hard-tab trailing-whitespace'], open: ['invisible-character trailing-whitespace']}
        {start: [1, 14], end: [1, 14], close: ['invisible-character trailing-whitespace'], open: []}
      ])

    it "renders end of line invisibles, appropriately decorated", ->
      buffer = new TextBuffer(text: "a\nb\n\nd e f\r\ngh\rij\n\r\n")
      displayLayer = buffer.addDisplayLayer({tabLength: 4, invisibles: {cr: '¤', eol: '¬'}})
      expect(displayLayer.getText()).toBe("a¬\nb¬\n¬\nd e f¤¬\ngh¤\nij¬\n¤¬\n")

      expectTokens(displayLayer, [
        {start: [0, 0], end: [0, 1], close: [], open: []}
        {start: [0, 1], end: [0, 2], close: [], open: ['invisible-character eol']}
        {start: [0, 2], end: [0, 2], close: ['invisible-character eol'], open: []}
        {start: [1, 0], end: [1, 1], close: [], open: []}
        {start: [1, 1], end: [1, 2], close: [], open: ['invisible-character eol']}
        {start: [1, 2], end: [1, 2], close: ['invisible-character eol'], open: []}
        {start: [2, 0], end: [2, 1], close: [], open: ['invisible-character eol']}
        {start: [2, 1], end: [2, 1], close: ['invisible-character eol'], open: []}
        {start: [3, 0], end: [3, 5], close: [], open: []}
        {start: [3, 5], end: [3, 7], close: [], open: ['invisible-character eol']}
        {start: [3, 7], end: [3, 7], close: ['invisible-character eol'], open: []}
        {start: [4, 0], end: [4, 2], close: [], open: []}
        {start: [4, 2], end: [4, 3], close: [], open: ['invisible-character eol']}
        {start: [4, 3], end: [4, 3], close: ['invisible-character eol'], open: []}
        {start: [5, 0], end: [5, 2], close: [], open: []}
        {start: [5, 2], end: [5, 3], close: [], open: ['invisible-character eol']}
        {start: [5, 3], end: [5, 3], close: ['invisible-character eol'], open: []}
        {start: [6, 0], end: [6, 2], close: [], open: ['invisible-character eol']}
        {start: [6, 2], end: [6, 2], close: ['invisible-character eol'], open: []}
        {start: [7, 0], end: [7, 0], close: [], open: []}
      ])

    it "does not clip positions within runs of invisible characters", ->
      buffer = new TextBuffer(text: "   a")
      displayLayer = buffer.addDisplayLayer({invisibles: {space: '•'}})
      expect(displayLayer.clipScreenPosition(Point(0, 2))).toEqual(Point(0, 2))

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

      verifyTokenIterator(displayLayer)
      expectTokens(displayLayer, [
        {start: [0, 0], end: [0, 1], close: [], open: []},
        {start: [0, 1], end: [0, 2], close: [], open: ['aa']},
        {start: [0, 2], end: [0, 3], close: [], open: ['ab']},
        {start: [0, 3], end: [0, 4], close: [], open: ['ac']},
        {start: [0, 4], end: [0, 5], close: ['ac', 'ab', 'aa'], open: ['ab', 'ac']},
        {start: [0, 5], end: [0, 5], close: ['ac', 'ab'], open: []},
        {start: [1, 0], end: [1, 2], close: [], open: ['ab', 'ac']},
        {start: [1, 2], end: [1, 3], close: ['ac', 'ab'], open: []},
        {start: [1, 3], end: [1, 5], close: [], open: ['ad']},
        {start: [1, 5], end: [1, 5], close: ['ad'], open: []},
        {start: [2, 0], end: [2, 3], close: [], open: []},
        {start: [2, 3], end: [2, 5], close: [], open: ['ae']},
        {start: [2, 5], end: [2, 5], close: ['ae'], open: []}
      ])

      tokenIterator = displayLayer.buildTokenIterator()

      tokenIterator.seekToScreenRow(0)
      expect(tokenIterator.getStartScreenPosition()).toEqual [0, 0]
      expect(tokenIterator.getEndScreenPosition()).toEqual [0, 1]
      expect(tokenIterator.getCloseTags()).toEqual []
      expect(tokenIterator.getOpenTags()).toEqual []

      tokenIterator.seekToScreenRow(1)
      expect(tokenIterator.getStartScreenPosition()).toEqual [1, 0]
      expect(tokenIterator.getEndScreenPosition()).toEqual [1, 2]
      expect(tokenIterator.getCloseTags()).toEqual []
      expect(tokenIterator.getOpenTags()).toEqual ['ab', 'ac']

      tokenIterator.seekToScreenRow(2)
      expect(tokenIterator.getStartScreenPosition()).toEqual [2, 0]
      expect(tokenIterator.getEndScreenPosition()).toEqual [2, 3]
      expect(tokenIterator.getCloseTags()).toEqual []
      expect(tokenIterator.getOpenTags()).toEqual []

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
        {start: [0, 0], end: [0, 1], close: [], open: []},
        {start: [0, 1], end: [0, 2], close: [], open: ['preceding-fold', 'ending-at-fold-start', 'overlapping-fold-start', 'surrounding-fold']},
        {start: [0, 2], end: [0, 3], close: ['surrounding-fold', 'overlapping-fold-start', 'ending-at-fold-start', 'preceding-fold'], open: ['ending-at-fold-start', 'overlapping-fold-start', 'surrounding-fold']},
        {start: [0, 3], end: [0, 4], close: ['surrounding-fold', 'overlapping-fold-start', 'ending-at-fold-start'], open: []},
        {start: [0, 4], end: [0, 6], close: [], open: ['surrounding-fold', 'overlapping-fold-end', 'starting-at-fold-end']},
        {start: [0, 6], end: [0, 7], close: ['starting-at-fold-end', 'overlapping-fold-end'], open: ['following-fold']},
        {start: [0, 7], end: [0, 7], close: ['following-fold', 'surrounding-fold'], open: []}
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

  it "updates the displayed text correctly when the underlying buffer changes", ->
    for i in [0...10] by 1
      seed = Date.now()
      seedFailureMessage = "Seed: #{seed}"
      random = new Random(seed)
      buffer = new TextBuffer(text: buildRandomLines(random, 10))
      invisibles = {}
      invisibles.space = '•' if random(2) > 0
      invisibles.eol = '¬' if random(2) > 0
      invisibles.cr = '¤' if random(2) > 0
      displayLayer = buffer.addDisplayLayer({tabLength: 4, patchSeed: seed, invisibles})
      textDecorationLayer = new TestDecorationLayer([], buffer, random)
      displayLayer.setTextDecorationLayer(textDecorationLayer)

      foldIds = []

      for j in [0...10] by 1
        k = random(10)
        if k < 2
          createRandomFold(random, displayLayer, foldIds, seedFailureMessage)
        else if k < 4 and foldIds.length > 0
          destroyRandomFold(random, displayLayer, foldIds, seedFailureMessage)
        else
          performRandomChange(random, buffer, displayLayer, seedFailureMessage)

        return if currentSpecFailed()

        # incrementally-updated text matches freshly computed text
        expectedDisplayLayer = buffer.addDisplayLayer({foldsMarkerLayer: displayLayer.foldsMarkerLayer.copy(), tabLength: 4, invisibles})
        expect(JSON.stringify(displayLayer.getText())).toBe(JSON.stringify(expectedDisplayLayer.getText()), seedFailureMessage)
        return if currentSpecFailed()

        # positions all translate correctly
        verifyPositionTranslations(displayLayer, expectedDisplayLayer, seedFailureMessage)
        return if currentSpecFailed()

        # token iterator matches contents of display layer
        verifyTokenIterator(displayLayer, textDecorationLayer, seedFailureMessage)
        return if currentSpecFailed()

        verifyRightmostScreenPosition(displayLayer, seedFailureMessage)
        return if currentSpecFailed()

        expectedDisplayLayer.destroy()

performRandomChange = (random, buffer, displayLayer, failureMessage) ->
  tries = 10
  range = getRandomRange(random, buffer)
  while displayLayer.foldsMarkerLayer.findMarkers(intersectsRange: range).length > 0
    range = getRandomRange(random, buffer)
    return if --tries is 0

  verifyChangeEvent displayLayer, failureMessage, ->
    text = buildRandomLines(random, 4)
    buffer.setTextInRange(range, text)

createRandomFold = (random, displayLayer, foldIds, failureMessage) ->
  verifyChangeEvent displayLayer, failureMessage, ->
    bufferRange = getRandomRange(random, displayLayer.buffer)
    foldId = displayLayer.foldBufferRange(bufferRange)
    foldIds.push(foldId)

destroyRandomFold = (random, displayLayer, foldIds, failureMessage) ->
  verifyChangeEvent displayLayer, failureMessage, ->
    [foldId] = foldIds.splice(random(foldIds.length - 1), 1)
    displayLayer.destroyFold(foldId)

verifyChangeEvent = (displayLayer, failureMessage, fn) ->
  if arguments.length is 2
    fn = failureMessage
    failureMessage = ''

  previousTokenLines = getTokenLines(displayLayer)
  lastChanges = null
  disposable = displayLayer.onDidChangeSync (changes) -> lastChanges = changes

  fn()

  disposable.dispose()
  if lastChanges?
    expectedTokenLines = getTokenLines(displayLayer)
    updateTokenLines(previousTokenLines, displayLayer, lastChanges)

    # npm install json-diff locally if you need to uncomment this code
    # {diffString} = require 'json-diff'
    # diff = diffString(expectedTokenLines, previousTokenLines, color: false)
    # console.log diff
    # console.log previousTokenLines
    # console.log expectedTokenLines

    expect(previousTokenLines).toEqual(expectedTokenLines, failureMessage)
  else
    expect(getTokenLines(displayLayer)).toEqual(previousTokenLines, failureMessage)

verifyTokenIterator = (displayLayer, textDecorationLayer, failureMessage) ->
  {buffer} = displayLayer
  tokenIterator = displayLayer.buildTokenIterator()
  tokenIterator.seekToScreenRow(0)

  text = ''
  lastTextRow = 0
  pendingOpenTags = []
  pendingCloseTags = []
  previousTokenWasFold = false
  containingTags = []
  loop
    startScreenPosition = tokenIterator.getStartScreenPosition()
    endScreenPosition = tokenIterator.getEndScreenPosition()
    startBufferPosition = tokenIterator.getStartBufferPosition()
    endBufferPosition = tokenIterator.getEndBufferPosition()

    expect(displayLayer.translateScreenPosition(startScreenPosition)).toEqual(startBufferPosition, failureMessage)
    expect(displayLayer.translateScreenPosition(endScreenPosition)).toEqual(endBufferPosition, failureMessage)
    expect(displayLayer.translateBufferPosition(startBufferPosition)).toEqual(startScreenPosition, failureMessage)
    expect(displayLayer.translateBufferPosition(endBufferPosition)).toEqual(endScreenPosition, failureMessage)

    if startScreenPosition.row > lastTextRow
      expect(startScreenPosition.row).toBe(lastTextRow + 1, failureMessage) # don't skip lines
      text += '\n'
      lastTextRow = startScreenPosition.row

    tokenText = tokenIterator.getText()
    expect(tokenText.indexOf('\n') is -1).toBe(true, failureMessage) # never include newlines in token text
    text += tokenText

    if textDecorationLayer?
      for tag in tokenIterator.getCloseTags()
        expect(containingTags.pop()).toBe(tag, "At screen position: #{tokenIterator.getStartScreenPosition()} " + failureMessage)
        return if currentSpecFailed()
      containingTags.push(tokenIterator.getOpenTags()...)

      if tokenIterator.isFold()
        expect(tokenIterator.getOpenTags()).toEqual([], failureMessage)
        expect(containingTags).toEqual([], failureMessage)
        previousTokenWasFold = true
      else
        if previousTokenWasFold
          expect(tokenIterator.getCloseTags()).toEqual([])
          previousTokenWasFold = false

        if tokenText.length > 0
          actualContainingTags = containingTags.filter((tag) -> not (tag in displayLayer.PATCH_TAGS)).sort()
          expectedContainingTags = textDecorationLayer.containingTagsForPosition(startBufferPosition).sort()
          expect(actualContainingTags).toEqual(expectedContainingTags, failureMessage)

    break unless tokenIterator.moveToSuccessor()

  expect(containingTags).toEqual([], failureMessage)
  expect(text).toBe(displayLayer.getText(), failureMessage)

verifyPositionTranslations = (actualDisplayLayer, expectedDisplayLayer, failureMessage) ->
  {buffer} = actualDisplayLayer

  bufferLines = buffer.getText().split('\n')
  screenLines = actualDisplayLayer.getText().split('\n')

  for bufferLine, bufferRow in bufferLines
    for character, bufferColumn in bufferLine
      actualPosition = actualDisplayLayer.translateBufferPosition(Point(bufferRow, bufferColumn))
      expectedPosition = expectedDisplayLayer.translateBufferPosition(Point(bufferRow, bufferColumn))
      expect(actualPosition).toEqual(expectedPosition, failureMessage)

  for screenLine, screenRow in screenLines
    for character, screenColumn in screenLine
      actualPosition = actualDisplayLayer.translateScreenPosition(Point(screenRow, screenColumn))
      expectedPosition = expectedDisplayLayer.translateScreenPosition(Point(screenRow, screenColumn))
      expect(actualPosition).toEqual(expectedPosition, failureMessage)

verifyRightmostScreenPosition = (displayLayer, failureMessage) ->
  screenLines = displayLayer.getText().split('\n')
  lastScreenRow = screenLines.length - 1

  maxLineLength = -1
  longestScreenRows = new Set
  for screenLine, row in screenLines
    screenLineLength = screenLine.length
    screenLineLength -= 1 if screenLine.indexOf(displayLayer.invisibles.cr) isnt -1
    screenLineLength -= 1 if screenLine.indexOf(displayLayer.invisibles.eol) isnt -1

    expect(displayLayer.lineLengthForScreenRow(row)).toBe(screenLineLength)

    if screenLineLength > maxLineLength
      longestScreenRows.clear()
      maxLineLength = screenLineLength

    if screenLineLength >= maxLineLength
      longestScreenRows.add(row)

  rightmostScreenPosition = displayLayer.getRightmostScreenPosition()
  expect(rightmostScreenPosition.column).toBe(maxLineLength, failureMessage)
  expect(longestScreenRows.has(rightmostScreenPosition.row)).toBe(true, failureMessage)

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
      expect(displayLayer.clipScreenPosition(screenPosition, clipDirection: 'backward')).toEqual(displayLayer.translateBufferPosition(backwardBufferPosition))
      expect(displayLayer.clipScreenPosition(screenPosition, clipDirection: 'forward')).toEqual(displayLayer.translateBufferPosition(forwardBufferPosition))
    else
      bufferPosition = bufferPositions
      expect(displayLayer.translateScreenPosition(screenPosition)).toEqual(bufferPosition)
      expect(displayLayer.translateBufferPosition(bufferPosition)).toEqual(screenPosition)

expectTokens = (displayLayer, expectedTokens) ->
  tokenIterator = displayLayer.buildTokenIterator()
  tokenIterator.seekToScreenRow(0)
  loop
    throw new Error("The actual tokens are more than the expected ones.") if expectedTokens.length is 0
    {start, end, text, open, close, containing} = expectedTokens.shift()
    expect(tokenIterator.getStartScreenPosition()).toEqual(start)
    expect(tokenIterator.getEndScreenPosition()).toEqual(end)
    expect(tokenIterator.getOpenTags()).toEqual(open, "Open tags of token with start position: #{start}, end position: #{end}")
    expect(tokenIterator.getCloseTags()).toEqual(close, "Close tags of token with start position #{start}, end position #{end}")
    break unless tokenIterator.moveToSuccessor()

getTokenLines = (displayLayer, startRow=0, endRow=displayLayer.getScreenLineCount()) ->
  lines = displayLayer.getText().split('\n')
  tokenIterator = displayLayer.buildTokenIterator()
  tokenIterator.seekToScreenRow(startRow)
  tokenLines = []
  tokenLine = []
  currentRow = startRow

  loop
    openTags = tokenIterator.getOpenTags()
    closeTags = tokenIterator.getCloseTags()
    startColumn = tokenIterator.getStartScreenPosition().column
    endColumn = tokenIterator.getEndScreenPosition().column
    text = lines[currentRow].substring(startColumn, endColumn)
    tokenLine.push({openTags, closeTags, text})

    unless tokenIterator.moveToSuccessor()
      tokenLines.push(tokenLine)
      break

    if tokenIterator.getStartScreenPosition().row > currentRow
      tokenLines.push(tokenLine)
      currentRow++
      if currentRow is endRow
        break
      else
        tokenLine = []

  tokenLines

updateTokenLines = (tokenLines, displayLayer, changes) ->
  for {start, oldExtent, newExtent} in changes
    tokenLines.splice(start.row, oldExtent.row, getTokenLines(displayLayer, start.row, start.row + newExtent.row)...)
