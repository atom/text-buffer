Point = require './point'

# Public: Represents a region in a buffer in row/column coordinates.
#
# Every public method that takes a range also accepts a *range-compatible*
# {Array}. This means a 2-element array containing {Point}s or point-compatible
# arrays. So the following are equivalent:
#
# ```coffee
# new Range(new Point(0, 1), new Point(2, 3))
# new Range([0, 1], [2, 3])
# [[0, 1], [2, 3]]
# ```
module.exports =
class Range
  # Public: Call this with the result of {Range.serialize} to construct a new Range.
  @deserialize: (array) ->
    new this(array...)

  # Public: Convert any range-compatible object to a {Range}.
  #
  # * object:
  #     This can be an object that's already a {Range}, in which case it's
  #     simply returned, or an array containing two {Point}s or point-compatible
  #     arrays.
  # * copy:
  #     An optional boolean indicating whether to force the copying of objects
  #     that are already ranges.
  #
  # Returns: A {Range} based on the given object.
  @fromObject: (object, copy) ->
    if Array.isArray(object)
      new this(object...)
    else if object instanceof this
      if copy then object.copy() else object
    else
      new this(object.start, object.end)

  # Returns a range based on an optional starting point and the given text. If
  # no starting point is given it will be assumed to be [0, 0].
  #
  # * startPoint: A {Point} where the range should start.
  # * text:
  #   A {String} after which the range should end. The range will have as many
  #   rows as the text has lines have an end column based on the length of the
  #   last line.
  #
  # Returns: A {Range}
  @fromText: (args...) ->
    if args.length > 1
      startPoint = Point.fromObject(args.shift())
    else
      startPoint = new Point(0, 0)
    text = args.shift()
    endPoint = startPoint.copy()
    lines = text.split('\n')
    if lines.length > 1
      lastIndex = lines.length - 1
      endPoint.row += lastIndex
      endPoint.column = lines[lastIndex].length
    else
      endPoint.column += lines[0].length
    new this(startPoint, endPoint)

  # Public: Returns a {Range} that starts at the given point and ends at the
  # start point plus the given row and column deltas.
  #
  # * startPoint:
  #     A {Point} or point-compatible {Array}
  # * rowDelta:
  #     A {Number} indicating how many rows to add to the start point to get the
  #     end point.
  # * columnDelta:
  #     A {Number} indicating how many rows to columns to the start point to get
  #     the end point.
  #
  # Returns a {Range}
  @fromPointWithDelta: (startPoint, rowDelta, columnDelta) ->
    startPoint = Point.fromObject(startPoint)
    endPoint = new Point(startPoint.row + rowDelta, startPoint.column + columnDelta)
    new this(startPoint, endPoint)

  constructor: (pointA = new Point(0, 0), pointB = new Point(0, 0)) ->
    pointA = Point.fromObject(pointA)
    pointB = Point.fromObject(pointB)

    if pointA.isLessThanOrEqual(pointB)
      @start = pointA
      @end = pointB
    else
      @start = pointB
      @end = pointA

  # Public: Returns a plain javascript object representation of the range.
  serialize: ->
    [@start.serialize(), @end.serialize()]

  # Public: Returns a new range with the same start and end positions.
  copy: ->
    new @constructor(@start.copy(), @end.copy())

  # Public: Freezes the range and its start and end point so it becomes
  # immutable and returns itself.
  freeze: ->
    @start.freeze()
    @end.freeze()
    Object.freeze(this)

  # Public: Returns a {Boolean} indicating whether this range has the same start
  # and end points as the given {Range} or range-compatible {Array}.
  isEqual: (other) ->
    return false unless other?

    if Array.isArray(other) and other.length == 2
      other = new @constructor(other...)

    other.start.isEqual(@start) and other.end.isEqual(@end)

  # Public:
  #
  # * other: A {Range} or range-compatible {Array}.
  #
  # Returns:
  #  * -1 if this range starts before the argument or contains it
  #  * 0 if this range is equivalent to the argument.
  #  * 1 if this range starts after the argument or is contained by it.
  compare: (other) ->
    other = @constructor.fromObject(other)
    if value = @start.compare(other.start)
      value
    else
      other.end.compare(@end)

  # Public: Returns a {Boolean} indicating whether this range starts and ends on
  # the same row.
  isSingleLine: ->
    @start.row is @end.row

  # Public: Returns a {Boolean} indicating whether this range starts and ends on
  # the same row as the argument.
  coversSameRows: (other) ->
    @start.row == other.start.row && @end.row == other.end.row

  add: (delta) ->
    new @constructor(@start.add(delta), @end.add(delta))

  translate: (startPoint, endPoint=startPoint) ->
    new @constructor(@start.translate(startPoint), @end.translate(endPoint))

  # Public: Determines whether this range intersects with the argument.
  intersectsWith: (otherRange) ->
    if @start.isLessThanOrEqual(otherRange.start)
      @end.isGreaterThanOrEqual(otherRange.start)
    else
      otherRange.intersectsWith(this)

  # Public: Returns a {Boolean} indicating whether this range contains the given
  # range.
  #
  # * otherRange: A {Range} or range-compatible {Array}
  # * exclusive:
  #   A boolean value including that the containment should be exclusive of
  #   endpoints. Defaults to false.
  containsRange: (otherRange, exclusive) ->
    {start, end} = @constructor.fromObject(otherRange)
    @containsPoint(start, exclusive) and @containsPoint(end, exclusive)

  # Public: Returns a {Boolean} indicating whether this range contains the given
  # point.
  #
  # * point: A {Point} or point-compatible {Array}
  # * exclusive:
  #   A boolean value including that the containment should be exclusive of
  #   endpoints. Defaults to false.
  containsPoint: (point, exclusive) ->
    # Deprecated: Support options hash with exclusive
    if exclusive? and typeof exclusive is 'object'
      {exclusive} = exclusive

    point = Point.fromObject(point)
    if exclusive
      point.isGreaterThan(@start) and point.isLessThan(@end)
    else
      point.isGreaterThanOrEqual(@start) and point.isLessThanOrEqual(@end)

  # Public: Returns a {Boolean} indicating whether this range intersects the
  # given row {Number}.
  intersectsRow: (row) ->
    @start.row <= row <= @end.row

  # Public: Returns a {Boolean} indicating whether this range intersects the
  # row range indicated by the given startRow and endRow {Number}s.
  intersectsRowRange: (startRow, endRow) ->
    [startRow, endRow] = [endRow, startRow] if startRow > endRow
    @end.row >= startRow and endRow >= @start.row

  # Public: Returns a new range that contains this range and the given range.
  union: (otherRange) ->
    start = if @start.isLessThan(otherRange.start) then @start else otherRange.start
    end = if @end.isGreaterThan(otherRange.end) then @end else otherRange.end
    new @constructor(start, end)

  # Public:
  isEmpty: ->
    @start.isEqual(@end)

  toDelta: ->
    rows = @end.row - @start.row
    if rows == 0
      columns = @end.column - @start.column
    else
      columns = @end.column
    new Point(rows, columns)

  # Public:
  getRowCount: ->
    @end.row - @start.row + 1

  # Public: Returns an array of all rows in the range.
  getRows: ->
    [@start.row..@end.row]

  # Public: Returns a string representation of the range.
  toString: ->
    "[#{@start} - #{@end}]"
