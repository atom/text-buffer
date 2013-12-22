Range = require './range'
{spliceArray} = require './helpers'

module.exports =
class TextBufferCore
  constructor: (options) ->
    @lines = ['']
    @lineEndings = ['']
    @setTextInRange([[0, 0], [0, 0]], options.text) if options?.text?

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
