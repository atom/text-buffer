TextBuffer = require '../src/text-buffer'
Point = require '../src/point'

describe "DisplayLayer", ->
  it "expands hard tab characters to tab stops", ->
    buffer = new TextBuffer(text: '\ta\tbc\tdef\tg\n\th')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    expect(displayLayer.getText()).toBe('    a   bc  def g\n    h')
    verifyPositionTranslations(displayLayer)

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
