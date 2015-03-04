module.exports =
class Point
  @zero: ->
    new Point(0, 0)

  constructor: (row, column) ->
    unless this instanceof Point
      return new Point(row, column)
    @row = row
    @column = column

  copy: ->
    new Point(@row, @column)
