Patch = require 'atom-patch'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
TokenIterator = require './token-iterator'
{traversal} = require './point-helpers'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, patchSeed}) ->
    @patch = new Patch(combineChanges: false, seed: patchSeed)
    @patchIterator = @patch.buildIterator()
    @buffer.onDidChange(@bufferDidChange.bind(this))
    @computeTransformation(0, @buffer.getLineCount())
    @emitter = new Emitter

  onDidChangeTextSync: (callback) ->
    @emitter.on 'did-change-text-sync', callback

  bufferDidChange: (change) ->
    {oldRange, newRange} = change
    startRow = oldRange.start.row
    oldEndRow = oldRange.end.row + 1
    newEndRow = newRange.end.row + 1
    {start, replacedExtent} = @patch.spliceInput(Point(startRow, 0), Point(oldEndRow - startRow, 0), Point(newEndRow - startRow, 0))
    newOutputEnd = @computeTransformation(startRow, newEndRow)
    replacementExtent = traversal(newOutputEnd, start)
    @emitter.emit 'did-change-text-sync', {start, replacedExtent, replacementExtent}

  computeTransformation: (startBufferRow, endBufferRow) ->
    {row: screenRow, column: screenColumn} = @translateBufferPosition(Point(startBufferRow, 0))
    for bufferRow in [startBufferRow...endBufferRow] by 1
      line = @buffer.lineForRow(bufferRow)
      for character, bufferColumn in line
        if character is '\t'
          tabText = ''
          tabText += ' ' for i in [0...@tabLength - (screenColumn % @tabLength)] by 1
          @patch.spliceWithText(Point(screenRow, screenColumn), Point(0, 1), tabText)
          screenColumn += tabText.length
        else
          screenColumn++
      screenRow++
      screenColumn = 0
    Point(screenRow, screenColumn)

  buildTokenIterator: ->
    new TokenIterator(@buffer, @patch.buildIterator())

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

  translateBufferPosition: (bufferPosition, options) ->
    bufferPosition = Point.fromObject(bufferPosition)

    @patchIterator.seekToInputPosition(bufferPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward'
        @patchIterator.getOutputEnd()
      else
        @patchIterator.getOutputStart()
    else
      @patchIterator.translateInputPosition(@buffer.clipPosition(bufferPosition, options))

  translateScreenPosition: (screenPosition, options) ->
    screenPosition = Point.fromObject(screenPosition)

    @patchIterator.seekToOutputPosition(screenPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward'
        @patchIterator.getInputEnd()
      else
        @patchIterator.getInputStart()
    else
      @buffer.clipPosition(@patchIterator.translateOutputPosition(screenPosition), options)

  clipScreenPosition: (screenPosition, options) ->
    screenPosition = Point.fromObject(screenPosition)

    @patchIterator.seekToOutputPosition(screenPosition)
    if @patchIterator.inChange()
      if options?.clipDirection is 'forward'
        @patchIterator.getOutputEnd()
      else
        @patchIterator.getOutputStart()
    else
      bufferPosition = @patchIterator.translateOutputPosition(screenPosition)
      clippedBufferPosition = @buffer.clipPosition(bufferPosition, options)
      @patchIterator.translateInputPosition(clippedBufferPosition)
