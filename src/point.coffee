module.exports =
class Point
  @zero: ->
    new Point(0, 0)

  @infinity: ->
    new Point(Infinity, Infinity)

  @min: (left, right) ->
    left = Point.fromObject(left)
    right = Point.fromObject(right)
    if left.compare(right) <= 0
      left
    else
      right

  @max: (left, right) ->
    left = Point.fromObject(left)
    right = Point.fromObject(right)
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
    other = Point.fromObject(other)
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

  isEqual: (other) ->
    @compare(other) is 0

  isLessThan: (other) ->
    @compare(other) is -1

  isLessThanOrEqual: (other) ->
    cmp = @compare(other)
    cmp is -1 or cmp is 0

  isGreaterThan: (other) ->
    @compare(other) is 1

  isGreaterThanOrEqual: (other) ->
    cmp = @compare(other)
    cmp is 1 or cmp is 0

  copy: ->
    new Point(@row, @column)

  negate: ->
    new Point(-@row, -@column)

  freeze: ->
    Object.freeze(this)

  isZero: ->
    @row is 0 and @column is 0

  isPositive: ->
    if @row > 0
      true
    else if @row < 0
      false
    else
      @column > 0

  sanitizeNegatives: ->
    if @row < 0
      new Point(0, 0)
    else if @column < 0
      new Point(@row, 0)
    else
      @copy()

  translate: (delta) ->
    delta = Point.fromObject(delta)
    new Point(@row + delta.row, @column + delta.column)

  traverse: (delta) ->
    delta = Point.fromObject(delta)
    if delta.row is 0
      new Point(@row, @column + delta.column)
    else
      new Point(@row + delta.row, delta.column)

  traversalFrom: (other) ->
    other = Point.fromObject(other)
    if @row is other.row
      if @column is Infinity and other.column is Infinity
        new Point(0, 0)
      else
        new Point(0, @column - other.column)
    else
      new Point(@row - other.row, @column)

  toArray: ->
    [@row, @column]

  serialize: ->
    @toArray()

  toString: ->
    "(#{@row}, #{@column})"
