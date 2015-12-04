Random = require 'random-seed'
TextBuffer = require '../src/text-buffer'
Point = require '../src/point'
Range = require '../src/range'
WORDS = require './helpers/words'
{currentSpecFailed} = require "./spec-helper"

describe "DisplayLayer", ->
  describe "hard tabs", ->
    it "expands hard tabs to their tab stops", ->
      buffer = new TextBuffer(text: '\ta\tbc\tdef\tg\n\th')
      displayLayer = buffer.addDisplayLayer(tabLength: 4)
      expect(displayLayer.getText()).toBe('    a   bc  def g\n    h')
      verifyPositionTranslations(displayLayer)
      verifyTokenIterator(displayLayer)

  it "updates the displayed text correctly when the underlying buffer changes", ->
    for i in [0...500] by 1
      seed = Date.now()
      seedFailureMessage = "Seed: #{seed}"
      random = new Random(seed)
      buffer = new TextBuffer(text: buildRandomLines(10, random))
      actualDisplayLayer = buffer.addDisplayLayer(tabLength: 4, patchSeed: seed)

      range = getRandomRange(buffer, random)
      text = buildRandomLines(4, random)
      buffer.setTextInRange(range, text)
      expectedDisplayLayer = buffer.addDisplayLayer(tabLength: 4)

      expect(actualDisplayLayer.getText()).toBe(expectedDisplayLayer.getText(), seedFailureMessage)
      return if currentSpecFailed()
      verifyTokenIterator(actualDisplayLayer, seedFailureMessage)
      return if currentSpecFailed()

verifyPositionTranslations = (displayLayer) ->
  {buffer} = displayLayer
  bufferLines = buffer.getText().split('\n')
  screenLines = displayLayer.getText().split('\n')

  for bufferLine, bufferRow in bufferLines
    for character, bufferColumn in bufferLine
      if character isnt '\t'
        bufferPosition = Point(bufferRow, bufferColumn)
        screenPosition = displayLayer.translateBufferPosition(bufferPosition)
        expect(screenLines[screenPosition.row][screenPosition.column]).toBe(character)
        expect(displayLayer.translateScreenPosition(screenPosition)).toEqual(bufferPosition)

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
