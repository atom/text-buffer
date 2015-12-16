Patch = require 'atom-patch'
{Emitter} = require 'event-kit'
Point = require './point'
Range = require './range'
TokenIterator = require './token-iterator'
{traversal} = require './point-helpers'
isPairedCharacter = require './is-paired-character'

module.exports =
class DisplayLayer
  constructor: (@buffer, {@tabLength, @patchSeed}) ->
    @patch = new Patch({combineChanges: false, seed: @patchSeed})
    @unpairedPatch = new Patch({combineChanges: false, seed: @patchSeed})
    @pendingUnpairedPatch = null
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
    screenSplice = @patch.spliceInput(Point(startRow, 0), Point(oldEndRow - startRow, 0), Point(newEndRow - startRow, 0))
    @pendingUnpairedPatch = new Patch(combineChanges: false, seed: @patchSeed)
    newOutputEnd = @computeTransformation(startRow, newEndRow)
    screenSplice.replacementExtent = traversal(newOutputEnd, screenSplice.start)
    @unpairedPatch.spliceInput(screenSplice.start, screenSplice.replacedExtent, screenSplice.replacementExtent)
    for {start, replacedExtent, replacementExtent, replacementText} in @pendingUnpairedPatch.getChanges()
      @unpairedPatch.splice(start, replacedExtent, replacementExtent, text: replacementText)
    @pendingUnpairedPatch = null
    @emitter.emit 'did-change-text-sync', screenSplice

  computeTransformation: (startBufferRow, endBufferRow) ->
    {row: screenRow} = @translateBufferPosition(Point(startBufferRow, 0))
    unpairedPatch = @pendingUnpairedPatch ? @unpairedPatch
    screenColumn = 0
    unpairedScreenColumn = 0

    for bufferRow in [startBufferRow...endBufferRow] by 1
      line = @buffer.lineForRow(bufferRow)
      bufferColumn = 0
      lineLength = line.length
      while bufferColumn < lineLength
        if line[bufferColumn] is '\t'
          tabText = ''
          tabText += ' ' for i in [0...@tabLength - (screenColumn % @tabLength)] by 1
          @patch.spliceWithText(Point(screenRow, screenColumn), Point(0, 1), tabText)
          bufferColumn += 1
          screenColumn += tabText.length
          unpairedScreenColumn += tabText.length
        else if isPairedCharacter(line.charCodeAt(bufferColumn), line.charCodeAt(bufferColumn + 1))
          characterText = line.substr(bufferColumn, 2)
          @patch.splice(Point(screenRow, screenColumn), Point(0, 2), Point(0, 1), text: characterText)
          unpairedPatch.splice(Point(screenRow, unpairedScreenColumn), Point(0, 1), Point(0, 2), text: characterText)
          bufferColumn += 2
          screenColumn += 1
          unpairedScreenColumn += 2
        else
          bufferColumn += 1
          screenColumn += 1
          unpairedScreenColumn += 1
      screenRow++
      screenColumn = 0
      unpairedScreenColumn = 0

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

  translateBufferPosition: (bufferPosition) ->
    @patch.translateInputPosition(bufferPosition)

  translateScreenPosition: (screenPosition) ->
    @patch.translateOutputPosition(screenPosition)

  characterIndexInLineForScreenPosition: (screenPosition) ->
    unpairedPosition = @unpairedPatch.translateInputPosition(screenPosition)
    unpairedPosition.column
