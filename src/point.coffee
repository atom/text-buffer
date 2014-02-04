# Public: Represents a point in a buffer in row/column coordinates.
#
# Every public method that takes a point also accepts a *point-compatible*
# {Array}. This means a 2-element array containing {Number}s representing the
# row and column. So the following are equivalent:
#
# ```coffee
# new Point(1, 2)
# [1, 2]
# ```
module.exports =
class Point
  # Public: Convert any point-compatible object to a {Point}.
  #
  # * object:
  #     This can be an object that's already a {Point}, in which case it's
  #     simply returned, or an array containing two {Number}s representing the
  #     row and column.
  #
  # * copy:
  #     An optional boolean indicating whether to force the copying of objects
  #     that are already points.
  #
  # Returns: A {Point} based on the given object.
  @fromObject: (object, copy) ->
    if object instanceof Point
      if copy then object.copy() else object
    else
      if Array.isArray(object)
        [row, column] = object
      else
        { row, column } = object

      new Point(row, column)

  # Public: Returns the given point that is earlier in the buffer.
  @min: (point1, point2) ->
    point1 = @fromObject(point1)
    point2 = @fromObject(point2)
    if point1.isLessThanOrEqual(point2)
      point1
    else
      point2

  constructor: (@row=0, @column=0) ->

  # Public: Returns a new {Point} with the same row and column.
  copy: ->
    new Point(@row, @column)

  # Public: Makes this point immutable and returns itself.
  freeze: ->
    Object.freeze(this)

  # Public: Return a new {Point} based on shifting this point by the given delta,
  # which is represented by another {Point}.
  translate: (delta) ->
    {row, column} = Point.fromObject(delta)
    new Point(@row + row, @column + column)

  add: (other) ->
    other = Point.fromObject(other)
    row = @row + other.row
    if other.row == 0
      column = @column + other.column
    else
      column = other.column

    new Point(row, column)

  splitAt: (column) ->
    if @row == 0
      rightColumn = @column - column
    else
      rightColumn = @column

    [new Point(0, column), new Point(@row, rightColumn)]

  # Public:
  #
  # * other: A {Point} or point-compatible {Array}.
  #
  # Returns:
  #  * -1 if this point precedes the argument.
  #  * 0 if this point is equivalent to the argument.
  #  * 1 if this point follows the argument.
  compare: (other) ->
    if @row > other.row
      1
    else if @row < other.row
      -1
    else
      if @column > other.column
        1
      else if @column < other.column
        -1
      else
        0

  # Public: Returns a {Boolean} indicating whether this point has the same row
  # and column as the given {Point} or point-compatible {Array}.
  isEqual: (other) ->
    return false unless other
    other = Point.fromObject(other)
    @row == other.row and @column == other.column

  # Public: Returns a {Boolean} indicating whether this point precedes the given
  # {Point} or point-compatible {Array}.
  isLessThan: (other) ->
    @compare(other) < 0

  # Public: Returns a {Boolean} indicating whether this point precedes or is
  # equal to the given {Point} or point-compatible {Array}.
  isLessThanOrEqual: (other) ->
    @compare(other) <= 0

  # Public: Returns a {Boolean} indicating whether this point follows the given
  # {Point} or point-compatible {Array}.
  isGreaterThan: (other) ->
    @compare(other) > 0

  # Public: Returns a {Boolean} indicating whether this point follows or is
  # equal to the given {Point} or point-compatible {Array}.
  isGreaterThanOrEqual: (other) ->
    @compare(other) >= 0

  # Public: Returns an array of this point's row and column.
  toArray: ->
    [@row, @column]

  # Public: Returns an array of this point's row and column.
  serialize: ->
    @toArray()

  # Public: Returns a string representation of the point.
  toString: ->
    "(#{@row}, #{@column})"
