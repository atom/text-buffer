'use strict'

exports.compare = (a, b) ->
  if a.row is b.row
    compareNumbers(a.column, b.column)
  else
    compareNumbers(a.row, b.row)

compareNumbers = (a, b) ->
  if a < b
    -1
  else if a > b
    1
  else
    0

exports.traverse = (start, distance) ->
  if distance.row is 0
    {
      row: start.row,
      column: start.column + distance.column
    }
  else
    {
      row: start.row + distance.row,
      column: distance.column
    }

exports.traversal = (end, start) ->
  if end.row is start.row
    {row: 0, column: end.column - start.column}
  else
    {row: end.row - start.row, column: end.column}

NEWLINE_REG_EXP = /\n/g

exports.characterIndexForPoint = (text, point) ->
  row = point.row
  column = point.column
  NEWLINE_REG_EXP.lastIndex = 0
  while row-- > 0
    unless NEWLINE_REG_EXP.exec(text)
      return text.length

  NEWLINE_REG_EXP.lastIndex + column
