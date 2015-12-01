TextBuffer = require '../src/text-buffer'

describe "DisplayLayer", ->
  it "expands hard tab characters to tab stops", ->
    buffer = new TextBuffer(text: '\ta\tbc\tdef\tg')
    displayLayer = buffer.addDisplayLayer(tabLength: 4)
    expect(displayLayer.getText()).toBe('    a   bc  def g')
