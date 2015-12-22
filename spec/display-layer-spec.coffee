Random = require 'random-seed'
TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'
{characterIndexForPoint} = require '../src/point-helpers'
WORDS = require './helpers/words'
SAMPLE_TEXT = require './helpers/sample-text'
{currentSpecFailed} = require "./spec-helper"

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

  it "updates the displayed text correctly when the underlying buffer changes", ->
    for i in [0...50] by 1
      seed = Date.now()
      seedFailureMessage = "Seed: #{seed}"
      random = new Random(seed)
      buffer = new TextBuffer(text: buildRandomLines(10, random))
      actualDisplayLayer = buffer.addDisplayLayer(tabLength: 4, patchSeed: seed)
      lastDisplayLayerChange = null
      actualDisplayLayer.onDidChangeTextSync (change) -> lastDisplayLayerChange = change

      for k in [0...10] by 1
        lastDisplayLayerChange = null
        range = getRandomRange(buffer, random)
        text = buildRandomLines(4, random)
        bufferWithDisplayLayerText = new TextBuffer(text: actualDisplayLayer.getText())
        buffer.setTextInRange(range, text)
        expectedDisplayLayer = buffer.addDisplayLayer(tabLength: 4)

        # incrementally-updated text matches freshly computed text
        expect(actualDisplayLayer.getText()).toBe(expectedDisplayLayer.getText(), seedFailureMessage)
        return if currentSpecFailed()

        # emitted text change event describes delta between the old and new text of display layer
        verifyChangeEvent(bufferWithDisplayLayerText, lastDisplayLayerChange, actualDisplayLayer, seedFailureMessage)
        return if currentSpecFailed()

        # token iterator matches contents of display layer
        verifyTokenIterator(actualDisplayLayer, seedFailureMessage)
        return if currentSpecFailed()

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

verifyChangeEvent = (bufferWithDisplayLayerText, lastDisplayLayerChange, actualDisplayLayer, seedFailureMessage) ->
  replacedRange = Range.fromPointWithTraversalExtent(lastDisplayLayerChange.start, lastDisplayLayerChange.replacedExtent)
  replacementRange = Range.fromPointWithTraversalExtent(lastDisplayLayerChange.start, lastDisplayLayerChange.replacementExtent)
  replacementText = substringForRange(actualDisplayLayer.getText(), replacementRange)
  bufferWithDisplayLayerText.setTextInRange(replacedRange, replacementText)
  expect(bufferWithDisplayLayerText.getText()).toBe(actualDisplayLayer.getText(), seedFailureMessage)

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

verifyPositionTranslations = (actualDisplayLayer, expectedDisplayLayer) ->
  {buffer} = displayLayer

  bufferLines = buffer.getText().split('\n')
  screenLines = actualDisplayLayer.getText().split('\n')

  for bufferLine, bufferRow in bufferLines
    for character, bufferColumn in bufferLine
      actualPosition = actualDisplayLayer.translateBufferPosition(Point(bufferRow, bufferColumn))
      expectedPosition = expectedDisplayLayer.translateBufferPosition(Point(bufferRow, bufferColumn))
      expect(actualPosition).toEqual(expectedPosition)

  for screenLine, screenRow in screenLines
    for character, screenColumn in screenLine
      actualPosition = actualDisplayLayer.translateScrneePosition(Point(screenRow, screenColumn))
      expectedPosition = expectedDisplayLayer.translateScreenPosition(Point(screenRow, screenColumn))
      expect(actualPosition).toEqual(expectedPosition)


buildRandomLines = (maxLines, random) ->
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

getRandomRange = (buffer, random) ->
  Range(getRandomPoint(buffer, random), getRandomPoint(buffer, random))

getRandomPoint = (buffer, random) ->
  row = random(buffer.getLineCount())
  column = random(buffer.lineForRow(row).length + 1)
  Point(row, column)

substringForRange = (text, range) ->
  startIndex = characterIndexForPoint(text, range.start)
  endIndex = characterIndexForPoint(text, range.end)
  text.substring(startIndex, endIndex)
