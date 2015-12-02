Patch = require 'atom-patch'
Point = require './point'
Range = require './range'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, patchSeed}) ->
    @patch = new Patch(patchSeed)
    @buffer.onDidChange(@bufferDidChange.bind(this))
    @computeTransformation(0, @buffer.getLineCount())

  bufferDidChange: (change) ->
    {oldRange, newRange} = change
    startRow = oldRange.start.row
    oldEndRow = oldRange.end.row + 1
    newEndRow = newRange.end.row + 1
    @patch.spliceInput(Point(startRow, 0), Point(oldEndRow - startRow, 0), Point(newEndRow - startRow, 0))
    @computeTransformation(startRow, newEndRow)

  computeTransformation: (startBufferRow, endBufferRow) ->
    screenRow = @translateBufferPosition(Point(startBufferRow, 0)).row
    for bufferRow in [startBufferRow...endBufferRow] by 1
      line = @buffer.lineForRow(bufferRow)
      screenColumn = 0
      for character, bufferColumn in line
        if character is '\t'
          tabText = ''
          tabText += ' ' for i in [0...@tabLength - (screenColumn % @tabLength)] by 1
          @patch.spliceWithText(Point(screenRow, screenColumn), Point(0, 1), tabText)
          screenColumn += tabText.length
        else
          screenColumn++
      screenRow++

  getText: ->
    text = ''

    {iterator} = @patch
    iterator.rewind()

    loop
      if iterator.inChange()
        text += iterator.getReplacementText()
      else
        text += @buffer.getTextInRange(Range(iterator.getInputStart(), iterator.getInputEnd()))
      break unless iterator.moveToSuccessor()

    text

  translateBufferPosition: (bufferPosition) ->
    @patch.translateInputPosition(bufferPosition)

  translateScreenPosition: (screenPosition) ->
    @patch.translateOutputPosition(screenPosition)
