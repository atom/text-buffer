module.exports =
class Point
  @zero: ->
    new Point(0, 0)

  @infinity: ->
    new Point(Infinity, Infinity)

  @min: (left, right) ->
    if left.compare(right) <= 0
      left
    else
      right

  @max: (left, right) ->
    if left.compare(right) >= 0
      left
    else
      right

  @fromObject: (object, copy) ->
    if object instanceof Point
      if copy then object.copy() else object
    else
      if Array.isArray(object)
        [row, column] = object
      else
        { row, column } = object

      new Point(row, column)

  constructor: (row, column) ->
    unless this instanceof Point
      return new Point(row, column)
    @row = row
    @column = column

  compare: (other) ->
    if @row > other.row
      1
    else if @row < other.row
      -1
    else if @column > other.column
      1
    else if @column < other.column
      -1
    else
      0

  copy: ->
    new Point(@row, @column)

  isZero: ->
    @row is 0 and @column is 0

  isPositive: ->
    if @row > 0
      true
    else
      @column > 0

  sanitizeNegatives: ->
    if @row < 0
      new Point(0, 0)
    else if @column < 0
      new Point(@row, 0)
    else
      @copy()

  traverse: (delta) ->
    if delta.row is 0
      new Point(@row, @column + delta.column)
    else
      new Point(@row + delta.row, delta.column)

  traversalFrom: (other) ->
    if @row is other.row
      if @column is Infinity and other.column is Infinity
        new Point(0, 0)
      else
        new Point(0, @column - other.column)
    else
      if @row is Infinity and other.row is Infinity
        new Point(0, @column)
      else
        new Point(@row - other.row, @column)

  toString: ->
    "(#{@row}, #{@column})"
