Grim = require 'grim'
Point = require './point'
{newlineRegex} = require './helpers'

# Public: Represents a region in a buffer in row/column coordinates.
#
# Every public method that takes a range also accepts a *range-compatible*
# {Array}. This means a 2-element array containing {Point}s or point-compatible
# arrays. So the following are equivalent:
#
# ## Examples
#
# ```coffee
# new Range(new Point(0, 1), new Point(2, 3))
# new Range([0, 1], [2, 3])
# [[0, 1], [2, 3]] # Range compatible array
# ```
module.exports =
class Range

  ###
  Section: Construction
  ###

  # Public: Convert any range-compatible object to a {Range}.
  #
  # * `object` This can be an object that's already a {Range}, in which case it's
  #   simply returned, or an array containing two {Point}s or point-compatible
  #   arrays.
  # * `copy` An optional boolean indicating whether to force the copying of objects
  #   that are already ranges.˚
  #
  # Returns: A {Range} based on the given object.
  @fromObject: (object, copy) ->
    if Array.isArray(object)
      new this(object[0], object[1])
    else if object instanceof this
      if copy then object.copy() else object
    else
      new this(object.start, object.end)

  # Returns a range based on an optional starting point and the given text. If
  # no starting point is given it will be assumed to be [0, 0].
  #
  # * `startPoint` (optional) {Point} where the range should start.
  # * `text` A {String} after which the range should end. The range will have as many
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
    lines = text.split(newlineRegex)
    if lines.length > 1
      lastIndex = lines.length - 1
      endPoint.row += lastIndex
      endPoint.column = lines[lastIndex].length
    else
      endPoint.column += lines[0].length
    new this(startPoint, endPoint)

  # Returns a {Range} that starts at the given point and ends at the
  # start point plus the given row and column deltas.
  #
  # * `startPoint` A {Point} or point-compatible {Array}
  # * `rowDelta` A {Number} indicating how many rows to add to the start point
  #   to get the end point.
  # * `columnDelta` A {Number} indicating how many rows to columns to the start
  #   point to get the end point.
  @fromPointWithDelta: (startPoint, rowDelta, columnDelta) ->
    startPoint = Point.fromObject(startPoint)
    endPoint = new Point(startPoint.row + rowDelta, startPoint.column + columnDelta)
    new this(startPoint, endPoint)

  ###
  Section: Serialization and Deserialization
  ###

  # Public: Call this with the result of {Range::serialize} to construct a new Range.
  #
  # * `array` {Array} of params to pass to the {::constructor}
  @deserialize: (array) ->
    if Array.isArray(array)
      new this(array[0], array[1])
    else
      new this()

  ###
  Section: Construction
  ###

  # Public: Construct a {Range} object
  #
  # * `pointA` {Point} or Point compatible {Array} (default: [0,0])
  # * `pointB` {Point} or Point compatible {Array} (default: [0,0])
  constructor: (pointA = new Point(0, 0), pointB = new Point(0, 0)) ->
    pointA = Point.fromObject(pointA)
    pointB = Point.fromObject(pointB)

    if pointA.isLessThanOrEqual(pointB)
      @start = pointA
      @end = pointB
    else
      @start = pointB
      @end = pointA

  # Public: Returns a new range with the same start and end positions.
  copy: ->
    new @constructor(@start.copy(), @end.copy())

  # Public: Returns a new range with the start and end positions negated.
  negate: ->
    new @constructor(@start.negate(), @end.negate())

  ###
  Section: Serialization and Deserialization
  ###

  # Public: Returns a plain javascript object representation of the range.
  serialize: ->
    [@start.serialize(), @end.serialize()]

  ###
  Section: Range Details
  ###

  # Public: Is the start position of this range equal to the end position?
  #
  # Returns a {Boolean}.
  isEmpty: ->
    @start.isEqual(@end)

  # Public: Returns a {Boolean} indicating whether this range starts and ends on
  # the same row.
  isSingleLine: ->
    @start.row is @end.row

  # Public: Get the number of rows in this range.
  #
  # Returns a {Number}.
  getRowCount: ->
    @end.row - @start.row + 1

  # Public: Returns an array of all rows in the range.
  getRows: ->
    [@start.row..@end.row]

  ###
  Section: Operations
  ###

  # Public: Freezes the range and its start and end point so it becomes
  # immutable and returns itself.
  #
  # Returns an immutable version of this {Range}
  freeze: ->
    @start.freeze()
    @end.freeze()
    Object.freeze(this)

  # Public: Returns a new range that contains this range and the given range.
  #
  # * `otherRange` A {Range} or range-compatible {Array}
  union: (otherRange) ->
    start = if @start.isLessThan(otherRange.start) then @start else otherRange.start
    end = if @end.isGreaterThan(otherRange.end) then @end else otherRange.end
    new @constructor(start, end)

  # Public: Build and return a new range by translating this range's start and
  # end points by the given delta(s).
  #
  # * `startDelta` A {Point} by which to translate the start of this range.
  # * `endDelta` (optional) A {Point} to by which to translate the end of this
  #   range. If omitted, the `startDelta` will be used instead.
  #
  # Returns a {Range}.
  translate: (startDelta, endDelta=startDelta) ->
    new @constructor(@start.translate(startDelta), @end.translate(endDelta))

  # Public: Build and return a new range by traversing this range's start and
  # end points by the given delta.
  #
  # See {Point::traverse} for details of how traversal differs from translation.
  #
  # * `delta` A {Point} containing the rows and columns to traverse to derive
  #   the new range.
  #
  # Returns a {Range}.
  traverse: (delta) ->
    new @constructor(@start.traverse(delta), @end.traverse(delta))

  ###
  Section: Comparison
  ###

  # Public: Compare two Ranges
  #
  # * `otherRange` A {Range} or range-compatible {Array}.
  #
  # Returns `-1` if this range starts before the argument or contains it.
  # Returns `0` if this range is equivalent to the argument.
  # Returns `1` if this range starts after the argument or is contained by it.
  compare: (other) ->
    other = @constructor.fromObject(other)
    if value = @start.compare(other.start)
      value
    else
      other.end.compare(@end)

  # Public: Returns a {Boolean} indicating whether this range has the same start
  # and end points as the given {Range} or range-compatible {Array}.
  #
  # * `otherRange` A {Range} or range-compatible {Array}.
  isEqual: (other) ->
    return false unless other?
    other = @constructor.fromObject(other)
    other.start.isEqual(@start) and other.end.isEqual(@end)

  # Public: Returns a {Boolean} indicating whether this range starts and ends on
  # the same row as the argument.
  #
  # * `otherRange` A {Range} or range-compatible {Array}.
  coversSameRows: (other) ->
    @start.row == other.start.row && @end.row == other.end.row

  # Public: Determines whether this range intersects with the argument.
  #
  # * `otherRange` A {Range} or range-compatible {Array}
  # * `exclusive` (optional) {Boolean} indicating whether to exclude endpoints
  #     when testing for intersection. Defaults to `false`.
  #
  # Returns a {Boolean}.
  intersectsWith: (otherRange, exclusive) ->
    if exclusive
      not (@end.isLessThanOrEqual(otherRange.start) or @start.isGreaterThanOrEqual(otherRange.end))
    else
      not (@end.isLessThan(otherRange.start) or @start.isGreaterThan(otherRange.end))

  # Public: Returns a {Boolean} indicating whether this range contains the given
  # range.
  #
  # * `otherRange` A {Range} or range-compatible {Array}
  # * `exclusive` A boolean value including that the containment should be exclusive of
  #   endpoints. Defaults to false.
  containsRange: (otherRange, exclusive) ->
    {start, end} = @constructor.fromObject(otherRange)
    @containsPoint(start, exclusive) and @containsPoint(end, exclusive)

  # Public: Returns a {Boolean} indicating whether this range contains the given
  # point.
  #
  # * `point` A {Point} or point-compatible {Array}
  # * `exclusive` A boolean value including that the containment should be exclusive of
  #   endpoints. Defaults to false.
  containsPoint: (point, exclusive) ->
    # Deprecated: Support options hash with exclusive
    if Grim.includeDeprecatedAPIs and exclusive? and typeof exclusive is 'object'
      Grim.deprecate("The second param is no longer an object, it's a boolean argument named `exclusive`.")
      {exclusive} = exclusive

    point = Point.fromObject(point)
    if exclusive
      point.isGreaterThan(@start) and point.isLessThan(@end)
    else
      point.isGreaterThanOrEqual(@start) and point.isLessThanOrEqual(@end)

  # Public: Returns a {Boolean} indicating whether this range intersects the
  # given row {Number}.
  #
  # * `row` Row {Number}
  intersectsRow: (row) ->
    @start.row <= row <= @end.row

  # Public: Returns a {Boolean} indicating whether this range intersects the
  # row range indicated by the given startRow and endRow {Number}s.
  #
  # * `startRow` {Number} start row
  # * `endRow` {Number} end row
  intersectsRowRange: (startRow, endRow) ->
    [startRow, endRow] = [endRow, startRow] if startRow > endRow
    @end.row >= startRow and endRow >= @start.row

  ###
  Section: Conversion
  ###

  toDelta: ->
    rows = @end.row - @start.row
    if rows == 0
      columns = @end.column - @start.column
    else
      columns = @end.column
    new Point(rows, columns)

  # Public: Returns a string representation of the range.
  toString: ->
    "[#{@start} - #{@end}]"

if Grim.includeDeprecatedAPIs
  Range::add = (delta) ->
    Grim.deprecate("Use Range::traverse instead")
    @traverse(delta)
