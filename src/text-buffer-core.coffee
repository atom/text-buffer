SpanSkipList = require 'span-skip-list'
Point = require './point'
Range = require './range'
{spliceArray} = require './helpers'

module.exports =
class TextBufferCore
  constructor: (options) ->
    @lines = ['']
    @lineEndings = ['']
    @offsetIndex = new SpanSkipList('rows', 'characters')
    @setTextInRange([[0, 0], [0, 0]], options?.text ? '')

  getText: ->
    text = ''
    for row in [0..@getLastRow()]
      text += (@lineForRow(row) + @lineEndingForRow(row))
    text

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
    range = Range.fromObject(range)
    startRow = range.start.row
    endRow = range.end.row
    rowCount = endRow - startRow + 1

    # Split inserted text into lines and line endings
    lines = text.split('\n')
    lineEndings = []
    for line, index in lines
      if line[-1..] is '\r'
        lines[index] = line[0...-1]
        lineEndings.push '\r\n'
      else
        lineEndings.push '\n'

    # Update first and last line so replacement preserves existing prefix and suffix of range
    lastIndex = lines.length - 1
    prefix = @lineForRow(startRow)[0...range.start.column]
    suffix = @lineForRow(endRow)[range.end.column...]
    lines[0] = prefix + lines[0]
    lines[lastIndex] += suffix
    lineEndings[lastIndex] = @lineEndingForRow(endRow)

    # Replace lines in range with new lines
    spliceArray(@lines, startRow, rowCount, lines)
    spliceArray(@lineEndings, startRow, rowCount, lineEndings)

    # Update the offset index for position <-> character offset translation
    offsets = lines.map (line, index) ->
      {rows: 1, characters: line.length + lineEndings[index].length}
    @offsetIndex.spliceArray('rows', startRow, rowCount, offsets)

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

  offsetForPosition: (position) ->
    {row, column} = Point.fromObject(position)

    if row < 0 or row > @getLastRow() or column < 0 or column > @lineLengthForRow(row)
      throw new Error("Position #{position} is invalid")

    {characters} = @offsetIndex.totalTo(row, 'rows')
    characters + column

  positionForOffset: (offset) ->
    if offset < 0 or offset > @getMaxOffset()
      throw new Error("Offset #{offset} is out of range")

    {rows, characters} = @offsetIndex.totalTo(offset, 'characters')
    if rows > @getLastRow()
      @getLastPosition()
    else
      new Point(rows, offset - characters)

  getMaxOffset: ->
    @offsetIndex.totalTo(Infinity, 'rows').characters
