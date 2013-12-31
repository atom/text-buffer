Delegator = require 'delegato'
Serializable = require 'nostalgia'
{Emitter} = require 'emissary'
SpanSkipList = require 'span-skip-list'
Point = require './point'
Range = require './range'
History = require './history'
MarkerManager = require './marker-manager'
BufferPatch = require './buffer-patch'
{spliceArray} = require './helpers'

module.exports =
class TextBuffer
  @Point: Point
  @Range: Range

  Delegator.includeInto(this)
  Emitter.includeInto(this)
  Serializable.includeInto(this)

  @delegatesMethods 'undo', 'redo', 'transact', 'beginTransaction', 'commitTransaction',
    'abortTransaction', 'isTransacting', 'clearUndoStack', toProperty: 'history'

  @delegatesMethods 'markRange', 'markPosition', 'getMarker', 'getMarkers',
    'findMarkers', toProperty: 'markers'

  constructor: (params) ->
    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new SpanSkipList('rows', 'characters')
    @setTextInRange([[0, 0], [0, 0]], params?.text ? '')
    @history = params?.history ? new History(this)
    @markers = params?.markers ? new MarkerManager(this)

  deserializeParams: (params) ->
    params.markers = MarkerManager.deserialize(params.markers, buffer: this)
    params.history = History.deserialize(params.history, buffer: this)
    params

  serializeParams: ->
    text: @getText()
    markers: @markers.serialize()
    history: @history.serialize()

  getText: ->
    text = ''
    for row in [0..@getLastRow()]
      text += (@lineForRow(row) + @lineEndingForRow(row))
    text

  getLines: ->
    @lines.slice()

  isEmpty: ->
    @getLastRow() is 0 and @lineLengthForRow(0) is 0

  getLineCount: ->
    @lines.length

  getLastRow: ->
    @getLineCount() - 1

  lineForRow: (row) ->
    @lines[row]

  lineEndingForRow: (row) ->
    @lineEndings[row]

  lineLengthForRow: (row) ->
    @lines[row].length

  setTextInRange: (range, text) ->
    patch = @buildPatch(range, text)
    @history?.recordNewPatch(patch)
    @applyPatch(patch)
    patch.newRange

  buildPatch: (oldRange, newText) ->
    oldRange = Range.fromObject(oldRange)
    oldText = @getTextInRange(oldRange)
    newRange = Range.fromText(oldRange.start, newText)
    patch = new BufferPatch(oldRange, newRange, oldText, newText)
    @markers?.handleBufferChange(patch)
    patch

  applyPatch: ({oldRange, newRange, oldText, newText, markerPatches}) ->
    startRow = oldRange.start.row
    endRow = oldRange.end.row
    rowCount = endRow - startRow + 1

    # Split inserted text into lines and line endings
    lines = newText.split('\n')
    lineEndings = []
    for line, index in lines
      if line[-1..] is '\r'
        lines[index] = line[0...-1]
        lineEndings.push '\r\n'
      else
        lineEndings.push '\n'

    # Update first and last line so replacement preserves existing prefix and suffix of oldRange
    lastIndex = lines.length - 1
    prefix = @lineForRow(startRow)[0...oldRange.start.column]
    suffix = @lineForRow(endRow)[oldRange.end.column...]
    lines[0] = prefix + lines[0]
    lines[lastIndex] += suffix
    lineEndings[lastIndex] = @lineEndingForRow(endRow)

    # Replace lines in oldRange with new lines
    spliceArray(@lines, startRow, rowCount, lines)
    spliceArray(@lineEndings, startRow, rowCount, lineEndings)

    # Update the offset index for position <-> character offset translation
    offsets = lines.map (line, index) ->
      {rows: 1, characters: line.length + lineEndings[index].length}
    @offsetIndex.spliceArray('rows', startRow, rowCount, offsets)

    @markers?.pauseChangeEvents()
    @markers?.applyPatches(markerPatches, true)
    @emit 'changed', {oldRange, newRange, oldText, newText}
    @markers?.resumeChangeEvents()
    @emit 'markers-updated'

  getTextInRange: (range) ->
    range = Range.fromObject(range)
    startRow = range.start.row
    endRow = range.end.row

    if startRow is endRow
      @lineForRow(startRow)[range.start.column...range.end.column]
    else
      text = ''
      for row in [startRow..endRow]
        line = @lineForRow(row)
        if row is startRow
          text += line[range.start.column...]
        else if row is endRow
          text += line[0...range.end.column]
          continue
        else
          text += line
        text += @lineEndingForRow(row)
      text

  clipRange: (range) ->
    range = Range.fromObject(range)
    start = @clipPosition(range.start)
    end = @clipPosition(range.end)
    if range.start.isEqual(start) and range.end.isEqual(end)
      range
    else
      new Range(start, end)

  clipPosition: (position) ->
    position = Point.fromObject(position)
    {row, column} = position
    if row < 0
      @getFirstPosition()
    else if row > @getLastRow()
      @getLastPosition()
    else
      column = Math.min(Math.max(column, 0), @lineLengthForRow(row))
      if column is position.column
        position
      else
        new Point(row, column)

  getFirstPosition: ->
    new Point(0, 0)

  getLastPosition: ->
    lastRow = @getLastRow()
    new Point(lastRow, @lineLengthForRow(lastRow))

  characterIndexForPosition: (position) ->
    {row, column} = Point.fromObject(position)

    if row < 0 or row > @getLastRow() or column < 0 or column > @lineLengthForRow(row)
      throw new Error("Position #{position} is invalid")

    {characters} = @offsetIndex.totalTo(row, 'rows')
    characters + column

  positionForCharacterIndex: (offset) ->
    if offset < 0 or offset > @getMaxOffset()
      throw new Error("Offset #{offset} is out of range")

    {rows, characters} = @offsetIndex.totalTo(offset, 'characters')
    if rows > @getLastRow()
      @getLastPosition()
    else
      new Point(rows, offset - characters)

  getMaxOffset: ->
    @offsetIndex.totalTo(Infinity, 'rows').characters
