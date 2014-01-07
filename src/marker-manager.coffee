IntervalSkipList = require 'interval-skip-list'
Serializable = require 'serializable'
Delegator = require 'delegato'
{omit, defaults, values, clone, compact, intersection, keys, max, size} = require 'underscore'
Marker = require './marker'
Point = require './point'
Range = require './range'

# Private: Manages the markers for a buffer.
module.exports =
class MarkerManager
  Serializable.includeInto(this)
  Delegator.includeInto(this)

  @delegatesMethods 'clipPosition', 'clipRange', toProperty: 'buffer'

  # Private: Counter used to give every marker a unique id.
  nextMarkerId: 1

  constructor: (@buffer, @markers) ->
    @intervals ?= @buildIntervals()
    if @markers?
      @nextMarkerId = parseInt(max(keys(@markers))) + 1
    else
      @markers = {}

  # Private: Builds the ::intervals indexing structure, which allows for quick
  # retrieval based on location.
  buildIntervals: ->
    new IntervalSkipList
      compare: (a, b) -> a.compare(b)
      minIndex: new Point(-Infinity, -Infinity)
      maxIndex: new Point(Infinity, Infinity)

  # Private: Called by {Serializable} during serialization
  serializeParams: ->
    markers = {}
    for id, marker of @markers
      markers[id] = marker.serialize()
    {markers}

  # Private: Called by {Serializable} during deserialization
  deserializeParams: (state) ->
    @intervals = @buildIntervals()
    for id, markerState of state.markers
      state.markers[id] = Marker.deserialize(markerState, manager: this)
    state

  # Public: Creates a marker with the given range. This marker will maintain
  # its logical location as the buffer is changed, so if you mark a particular
  # word, the marker will remain over that word even if the word's location in
  # the buffer changes.
  #
  # * range: A {Range} or range-compatible {Array}
  # * properties:
  #     A hash of key-value pairs to associate with the marker. There are also
  #     reserved property names that have marker-specific meaning:
  #     + reversed:
  #         Creates the marker in a reversed orientation. Defaults to false.
  #     + persistent:
  #         Whether to include this marker when serializing the buffer. Defaults
  #         to true.
  #     + invalidate:
  #         Determines the rules by which changes to the buffer *invalidate* the
  #         marker. Defaults to 'overlap', but can be any of the following:
  #         + 'never':
  #             The marker is never marked as invalid. This is a good choice for
  #             markers representing selections in an editor.
  #         + 'surround':
  #             The marker is invalidated by changes that completely surround it.
  #         + 'overlap':
  #             The marker is invalidated by changes that surround the start or
  #             end of the marker. This is the default.
  #         + 'inside':
  #             The marker is invalidated by a change that touches the marked
  #             region in any way. This is the most fragile strategy.
  #
  # Returns a {Marker}
  markRange: (range, properties) ->
    range = @clipRange(Range.fromObject(range, true)).freeze()
    params = Marker.extractParams(properties)
    params.range = range
    @createMarker(params)

  # Public: Creates a tail-less marker at the given position.
  #
  # * position: A {Point} or point-compatible {Array}
  # * properties: This is the same as the `properties` parameter in {::markRange}
  #
  # Returns a {Marker}
  markPosition: (position, properties) ->
    @markRange(new Range(position, position), defaults({tailed: false}, properties))

  # Public: Retrieves a marker by its id.
  getMarker: (id) ->
    @markers[id]

  # Public: Returns an {Array} of all {Marker}s on the buffer.
  getMarkers: ->
    values(@markers)

  # Public: Returns the number of markers on the buffer
  getMarkerCount: ->
    size(@markers)

  # Finds markers conforming to the given parameters.
  #
  # * params:
  #   A hash of key-value pairs constraining the set of returned markers. You can
  #   query against custom marker properties by listing the desired key-value
  #   pairs here. In addition, the following keys are reserved and have special
  #   semantics:
  #   * 'startPosition': Only include markers that start at the given {Point}.
  #   * 'endPosition': Only include markers that end at the given {Point}.
  #   * 'containsPoint': Only include markers that contain the given {Point}, inclusive.
  #   * 'containsRange': Only include markers that contain the given {Range}, inclusive.
  #   * 'startRow': Only include markers that start at the given row {Number}.
  #   * 'endRow': Only include markers that end at the given row {Number}.
  #   * 'intersectsRow': Only include markers that intersect the given row {Number}.
  #
  # Returns an {Array} of markers conforming to *all* the given parameters, sorted
  # by marker start position ascending, then by marker end position descending.
  # I.e. markers always sort earlier than markers they contain or precede in the
  # buffer.
  findMarkers: (params) ->
    params = clone(params)
    candidateIds = []
    for key, value of params
      switch key
        when 'startPosition'
          candidateIds.push(@intervals.findStartingAt(Point.fromObject(value)))
          delete params[key]
        when 'endPosition'
          candidateIds.push(@intervals.findEndingAt(Point.fromObject(value)))
          delete params[key]
        when 'containsPoint'
          candidateIds.push(@intervals.findContaining(Point.fromObject(value)))
          delete params[key]
        when 'containsRange'
          range = Range.fromObject(value)
          candidateIds.push(@intervals.findContaining(range.start, range.end))
          delete params[key]
        when 'startRow'
          candidateIds.push(@intervals.findStartingIn(new Point(value, 0), new Point(value, Infinity)))
          delete params[key]
        when 'endRow'
          candidateIds.push(@intervals.findEndingIn(new Point(value, 0), new Point(value, Infinity)))
          delete params[key]
        when 'intersectsRow'
          candidateIds.push(@intervals.findIntersecting(new Point(value, 0), new Point(value, Infinity)))
          delete params[key]

    if candidateIds.length > 0
      candidates = compact(intersection(candidateIds...).map((id) => @getMarker(id)))
    else
      candidates = @getMarkers()
    markers = candidates.filter (marker) -> marker.matchesParams(params)
    markers.sort (a, b) -> a.compare(b)

  # Private:
  createMarker: (params) ->
    params.manager = this
    params.id = @nextMarkerId++
    marker = new Marker(params)
    @markers[marker.id] = marker
    @buffer.emit 'marker-created', marker
    marker

  # Private:
  removeMarker: (id) ->
    delete @markers[id]

  # Private:
  recordMarkerPatch: (patch) ->
    if @buffer.isTransacting()
      @buffer.history.recordNewPatch(patch)

  # Private: Updates markers based on the given {BufferPatch}.
  handleBufferChange: (patch) ->
    marker.handleBufferChange(patch) for id, marker of @markers

  # Private: Updates all markers based on a hash of patches indexed by marker id.
  applyPatches: (markerPatches, textChanged) ->
    for id, patch of markerPatches
      @getMarker(id)?.applyPatch(patch, textChanged)

  # Private:
  pauseChangeEvents: ->
    marker.pauseEvents('changed') for marker in @getMarkers()

  # Private:
  resumeChangeEvents: ->
    marker.resumeEvents('changed') for marker in @getMarkers()
