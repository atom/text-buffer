Random = require 'random-seed'
TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'
{characterIndexForPoint} = require '../src/point-helpers'
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

  describe "text decorations", ->
    it "exposes decorations from all text decoration layers in the token iterator", ->
      buffer = new TextBuffer(text: """
        abcde
        fghij
        klmno
      """)

      displayLayer = buffer.addDisplayLayer()
      displayLayer.addTextDecorationLayer(new TestDecorationLayer([
        ['aa', [[0, 1], [0, 4]]]
        ['ab', [[0, 2], [1, 2]]]
        ['ac', [[1, 3], [2, 0]]]
        ['ad', [[2, 3], [2, 5]]]
      ]))
      displayLayer.addTextDecorationLayer(new TestDecorationLayer([
        ['ba', [[0, 2], [2, 1]]]
        ['bb', [[2, 1], [2, 5]]]
      ]))

      verifyTokenIterator(displayLayer)
      expectTokens(displayLayer, [
        {start: [0, 0], end: [0, 1], open: [], close: []},
        {start: [0, 1], end: [0, 2], open: ['aa'], close: []},
        {start: [0, 2], end: [0, 4], open: ['ab', 'ba'], close: ['aa']},
        {start: [0, 4], end: [0, 5], open: [], close: []},
        {start: [1, 0], end: [1, 2], open: [], close: ['ab']},
        {start: [1, 2], end: [1, 3], open: [], close: []},
        {start: [1, 3], end: [1, 5], open: ['ac'], close: []},
        {start: [2, 0], end: [2, 0], open: [], close: ['ac']},
        {start: [2, 0], end: [2, 1], open: [], close: ['ba']},
        {start: [2, 1], end: [2, 3], open: ['bb'], close: []},
        {start: [2, 3], end: [2, 5], open: ['ad'], close: ['bb', 'ad']}
      ])

      tokenIterator = displayLayer.buildTokenIterator()

      expect(tokenIterator.seekToScreenRow(0)).toEqual []
      expect(tokenIterator.getStartScreenPosition()).toEqual [0, 0]
      expect(tokenIterator.getEndScreenPosition()).toEqual [0, 1]
      expect(tokenIterator.getOpenTags()).toEqual []
      expect(tokenIterator.getCloseTags()).toEqual []

      expect(tokenIterator.seekToScreenRow(1)).toEqual ['ab', 'ba']
      expect(tokenIterator.getStartScreenPosition()).toEqual [1, 0]
      expect(tokenIterator.getEndScreenPosition()).toEqual [1, 2]
      expect(tokenIterator.getOpenTags()).toEqual []
      expect(tokenIterator.getCloseTags()).toEqual ['ab']

      expect(tokenIterator.seekToScreenRow(2)).toEqual ['ba']
      expect(tokenIterator.getStartScreenPosition()).toEqual [2, 0]
      expect(tokenIterator.getEndScreenPosition()).toEqual [2, 1]
      expect(tokenIterator.getOpenTags()).toEqual []
      expect(tokenIterator.getCloseTags()).toEqual ['ba']

  it "updates the displayed text correctly when the underlying buffer changes", ->
    for i in [0...50] by 1
      seed = Date.now()
      seedFailureMessage = "Seed: #{seed}"
      random = new Random(seed)
      buffer = new TextBuffer(text: buildRandomLines(random, 10))
      displayLayer = buffer.addDisplayLayer(tabLength: 4, patchSeed: seed)
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
        expectedDisplayLayer = buffer.addDisplayLayer(foldsMarkerLayer: displayLayer.foldsMarkerLayer.copy(), tabLength: 4)
        expect(JSON.stringify(displayLayer.getText())).toBe(JSON.stringify(expectedDisplayLayer.getText()), seedFailureMessage)
        return if currentSpecFailed()

        # positions all translate correctly
        verifyPositionTranslations(displayLayer, expectedDisplayLayer, seedFailureMessage)

        # token iterator matches contents of display layer
        verifyTokenIterator(displayLayer, seedFailureMessage)
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
    updateTokenLines(previousTokenLines, displayLayer, lastChanges)
    expect(previousTokenLines).toEqual(getTokenLines(displayLayer), failureMessage)
  else
    expect(getTokenLines(displayLayer)).toEqual(previousTokenLines, failureMessage)

verifyTokenIterator = (displayLayer, failureMessage) ->
  {buffer} = displayLayer
  tokenIterator = displayLayer.buildTokenIterator()
  tokenIterator.seekToScreenRow(0)

  text = ''
  lastTextRow = 0
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

    break unless tokenIterator.moveToSuccessor()

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
  for {start, replacedExtent, replacementExtent} in changes
    tokenLines.splice(start.row, replacedExtent.row, getTokenLines(displayLayer, start.row, start.row + replacementExtent.row)...)
