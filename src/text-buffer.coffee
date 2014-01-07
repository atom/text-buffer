Delegator = require 'delegato'
Serializable = require 'serializable'
{Emitter} = require 'emissary'
SpanSkipList = require 'span-skip-list'
diff = require 'diff'
Point = require './point'
Range = require './range'
History = require './history'
MarkerManager = require './marker-manager'
BufferPatch = require './buffer-patch'
{spliceArray} = require './helpers'

# Public: A mutable text container with undo/redo support and the ability to
# annotate logical regions in the text.
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
    'findMarkers', 'getMarkerCount', toProperty: 'markers'

  cachedText: null

  # Public:
  # * text: An optional string of Text with which to initialize the buffer.
  constructor: (params) ->
    text = params if typeof params is 'string'
    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new SpanSkipList('rows', 'characters')
    @setTextInRange([[0, 0], [0, 0]], text ? params?.text ? '', false)
    @history = params?.history ? new History(this)
    @markers = params?.markers ? new MarkerManager(this)

  # Private: Called by {Serializable} mixin during deserialization.
  deserializeParams: (params) ->
    params.markers = MarkerManager.deserialize(params.markers, buffer: this)
    params.history = History.deserialize(params.history, buffer: this)
    params

  # Private: Called by {Serializable} mixin during serialization.
  serializeParams: ->
    text: @getText()
    markers: @markers.serialize()
    history: @history.serialize()

  # Public: Returns a {String} representing the entire contents of the buffer.
  getText: ->
    if @cachedText?
      @cachedText
    else
      text = ''
      for row in [0..@getLastRow()]
        text += (@lineForRow(row) + @lineEndingForRow(row))
      @cachedText = text

  # Public: Returns an {Array} of {String}s representing all the lines in the
  # buffer, without line endings.
  getLines: ->
    @lines.slice()

  # Public:
  isEmpty: ->
    @getLastRow() is 0 and @lineLengthForRow(0) is 0

  # Public: Returns a {Number} representing the number of lines in the buffer.
  getLineCount: ->
    @lines.length

  # Public: Returns a {Number} representing the last zero-indexed row number of
  # the buffer.
  getLastRow: ->
    @getLineCount() - 1

  # Public: Returns a {String} representing the contents of the line at the
  # given row.
  #
  # * row - A {Number} representing a zero-indexed row.
  lineForRow: (row) ->
    @lines[row]

  # Public: Returns a {String} representing the line ending for the given row.
  #
  # * row - A {Number} indicating the row.
  #
  # Returns '\n', '\r\n', or '' for the last line of the buffer.
  lineEndingForRow: (row) ->
    @lineEndings[row]

  # Public: Returns a {Number} representing the line length for the given row,
  # exclusive of its line-ending character(s).
  #
  # row - A {Number} indicating the row.
  lineLengthForRow: (row) ->
    @lines[row].length

  # Public: Replaces the entire contents of the buffer with the given {String}
  setText: (text) ->
    @setTextInRange(@getRange(), text, false)

  # Public: Replaces the current buffer contents by applying a diff against
  # the given contents.
  #
  # * text: A {String} containing the new buffer contents.
  setTextViaDiff: (text) ->
    currentText = @getText()
    return if currentText == text

    endsWithNewline = (str) ->
      /[\r\n]+$/g.test(str)

    computeBufferColumn = (str) ->
      newlineIndex = Math.max(str.lastIndexOf('\n'), str.lastIndexOf('\r'))
      if endsWithNewline(str)
        0
      else if newlineIndex == -1
        str.length
      else
        str.length - newlineIndex - 1

    @transact =>
      row = 0
      column = 0
      currentPosition = [0, 0]

      lineDiff = diff.diffLines(currentText, text)
      changeOptions = normalizeLineEndings: false

      for change in lineDiff
        lineCount = change.value.match(/\n/g)?.length ? 0
        currentPosition[0] = row
        currentPosition[1] = column

        if change.added
          @setTextInRange([currentPosition, currentPosition], change.value, changeOptions)
          row += lineCount
          column = computeBufferColumn(change.value)

        else if change.removed
          endRow = row + lineCount
          endColumn = column + computeBufferColumn(change.value)
          @setTextInRange([currentPosition, [endRow, endColumn]], '', changeOptions)

        else
          row += lineCount
          column = computeBufferColumn(change.value)

  # Public: Sets the text in the given range.
  #
  # * range: A {Range}
  # * text: A {String}
  #
  # Returns the {Range} of the inserted text.
  setTextInRange: (range, text, normalizeLineEndings=true) ->
    patch = @buildPatch(range, text, normalizeLineEndings)
    @history?.recordNewPatch(patch)
    @applyPatch(patch)
    patch.newRange

  # Private: Builds a {BufferPatch}, which is used to modify the buffer and is
  # also pushed into the undo history so it can be undone.
  buildPatch: (oldRange, newText, normalizeLineEndings) ->
    oldRange = @clipRange(oldRange)
    oldText = @getTextInRange(oldRange)
    newRange = Range.fromText(oldRange.start, newText)
    patch = new BufferPatch(oldRange, newRange, oldText, newText, normalizeLineEndings)
    @markers?.handleBufferChange(patch)
    patch

  # Private: Applies a {BufferPatch} to the buffer based on its old range and
  # new text. Also applies any {MarkerPatch}es associated with the {BufferPatch}.
  applyPatch: ({oldRange, newRange, oldText, newText, normalizeLineEndings, markerPatches}) ->
    @cachedText = null

    startRow = oldRange.start.row
    endRow = oldRange.end.row
    rowCount = endRow - startRow + 1

    # Determine how to normalize the line endings of inserted text if enabled
    if normalizeLineEndings
      normalizedEnding = @lineEndingForRow(startRow)
      if normalizedEnding is ''
        if startRow > 0
          normalizedEnding = @lineEndingForRow(startRow - 1)
        else
          normalizedEnding = null

    # Split inserted text into lines and line endings
    lines = newText.split('\n')
    lineEndings = []
    for line, index in lines
      if line[-1..] is '\r'
        lines[index] = line[0...-1]
        lineEndings.push(normalizedEnding ? '\r\n')
      else
        lineEndings.push(normalizedEnding ? '\n')

    # Update first and last line so replacement preserves existing prefix and suffix of oldRange
    lastIndex = lines.length - 1
    prefix = @lineForRow(startRow)[0...oldRange.start.column]
    suffix = @lineForRow(endRow)[oldRange.end.column...]
    lines[0] = prefix + lines[0]
    lines[lastIndex] += suffix
    lastLineEnding = @lineEndingForRow(endRow)
    lastLineEnding = normalizedEnding if lastLineEnding isnt '' and normalizedEnding?
    lineEndings[lastIndex] = lastLineEnding

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

  # Public: Returns a {String} of text in the given {Range}.
  getTextInRange: (range) ->
    range = @clipRange(Range.fromObject(range))
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

  # Public: Clips the given range so it starts and ends at valid positions if
  # its start or end are out of bounds. For example, the position [1, 100] is
  # out of bounds if the line at row 1 is only 10 characters long, and it would
  # be clipped to (1, 10).
  #
  # * range: A {Range} to clip.
  #
  # Returns: The given {Range} if it is already in bounds, or a new clipped
  # {Range} if the given range is out-of-bounds.
  clipRange: (range) ->
    range = Range.fromObject(range)
    start = @clipPosition(range.start)
    end = @clipPosition(range.end)
    if range.start.isEqual(start) and range.end.isEqual(end)
      range
    else
      new Range(start, end)

  # Public: Clips the given point so it is at a valid position in the buffer.
  # For example, the position (1, 100) is out of bounds if the line at row 1 is
  # only 10 characters long, and it would be clipped to (1, 10)
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

  # Public: Returns a {Point} at [0, 0]
  getFirstPosition: ->
    new Point(0, 0)

  # Public: Returns a {Point} representing the maximal position in the buffer.
  getLastPosition: ->
    lastRow = @getLastRow()
    new Point(lastRow, @lineLengthForRow(lastRow))

  # Public: Returns a {Range} associated with the text of the entire buffer,
  # from its first position to its last position.
  getRange: ->
    new Range(@getFirstPosition(), @getLastPosition())

  # Public: Returns the range for the given row
  #
  # * row: A {Number}
  # * includeNewline:
  #     Whether or not to include the newline, resulting in a range that extends
  #     to the start of the next line.
  #
  # Returns a {Range}.
  rangeForRow: (row, includeNewline) ->
    # Handle deprecated options hash
    if typeof includeNewline is 'object'
      {includeNewline} = includeNewline

    if includeNewline and row < @getLastRow()
      new Range(new Point(row, 0), new Point(row + 1, 0))
    else
      new Range(new Point(row, 0), new Point(row, @lineLengthForRow(row)))

  # Public: Given a {Point} representing a position in the buffer, returns a
  # {Number} representing the absolute character offset of that location in the
  # buffer, inclusive of newlines. The position is clipped prior to translating.
  characterIndexForPosition: (position) ->
    {row, column} = @clipPosition(Point.fromObject(position))

    if row < 0 or row > @getLastRow() or column < 0 or column > @lineLengthForRow(row)
      throw new Error("Position #{position} is invalid")

    {characters} = @offsetIndex.totalTo(row, 'rows')
    characters + column

  # Public: Given a {Number} represting an absolute offset in the buffer,
  # inclusive of newlines, returns a {Point} representing that numbers
  # corresponding position in row/column coordinates. The offset is clipped
  # prior to translating.
  positionForCharacterIndex: (offset) ->
    offset = Math.max(0, offset)
    offset = Math.min(@getMaxCharacterIndex(), offset)

    {rows, characters} = @offsetIndex.totalTo(offset, 'characters')
    if rows > @getLastRow()
      @getLastPosition()
    else
      new Point(rows, offset - characters)

  # Public: Returns the length of the buffer in characters.
  getMaxCharacterIndex: ->
    @offsetIndex.totalTo(Infinity, 'rows').characters
