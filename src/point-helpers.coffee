Point = require './point'

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
    Point(start.row, start.column + distance.column)
  else
    Point(start.row + distance.row, distance.column)

exports.traversal = (end, start) ->
  if end.row is start.row
    Point(0, end.column - start.column)
  else
    Point(end.row - start.row, end.column)

NEWLINE_REG_EXP = /\n/g

exports.characterIndexForPoint = (text, point) ->
  row = point.row
  column = point.column
  NEWLINE_REG_EXP.lastIndex = 0
  while row-- > 0
    unless NEWLINE_REG_EXP.exec(text)
      return text.length

  NEWLINE_REG_EXP.lastIndex + column

exports.clipNegativePoint = (point) ->
  if point.row < 0 or point.column < 0
    Point(Math.max(0, point.row), Math.max(0, point.column))
  else
    point


exports.max = (a, b) ->
  if exports.compare(a, b) >= 0
    a
  else
    b
