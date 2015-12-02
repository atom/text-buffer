Patch = require 'atom-patch'
Point = require './point'
Range = require './range'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength}) ->
    @patch = new Patch

    screenRow = 0
    for line, bufferRow in @buffer.getLines()
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

    text += @buffer.getTextInRange(Range(iterator.getInputStart(), iterator.getInputEnd()))
    text

  translateBufferPosition: (bufferPosition) ->
    @patch.translateInputPosition(bufferPosition)

  translateScreenPosition: (screenPosition) ->
    @patch.translateOutputPosition(screenPosition)
