Point = require "../src/point"
Range = require "../src/range"
MarkerIndex = require "../src/marker-index"
Random = require "random-seed"

{currentSpecFailed, toEqualSet} = require "./spec-helper"

describe "MarkerIndex", ->
  markerIndex = null

  beforeEach ->
    @addMatchers({toEqualSet})
    markerIndex = new MarkerIndex

  describe "::getRange(id)", ->
    it "returns the range for the given marker id", ->
      markerIndex.insert("a", Point(0, 2), Point(0, 5))
      markerIndex.insert("b", Point(0, 3), Point(0, 7))
      markerIndex.insert("c", Point(0, 4), Point(0, 4))
      markerIndex.insert("d", Point(0, 0), Point(0, 0))
      markerIndex.insert("e", Point(0, 0), Point(0, 0))
      markerIndex.insert("f", Point(0, 3), Point(0, 3))
      markerIndex.insert("g", Point(0, 3), Point(0, 3))

      expect(markerIndex.getRange("a")).toEqual Range(Point(0, 2), Point(0, 5))
      expect(markerIndex.getRange("b")).toEqual Range(Point(0, 3), Point(0, 7))
      expect(markerIndex.getRange("c")).toEqual Range(Point(0, 4), Point(0, 4))
      expect(markerIndex.getRange("d")).toEqual Range(Point(0, 0), Point(0, 0))
      expect(markerIndex.getRange("e")).toEqual Range(Point(0, 0), Point(0, 0))
      expect(markerIndex.getRange("f")).toEqual Range(Point(0, 3), Point(0, 3))
      expect(markerIndex.getRange("g")).toEqual Range(Point(0, 3), Point(0, 3))

      markerIndex.delete("e")
      markerIndex.delete("c")
      markerIndex.delete("a")
      markerIndex.delete("f")

      expect(markerIndex.getRange("a")).toBeUndefined()
      expect(markerIndex.getRange("b")).toEqual Range(Point(0, 3), Point(0, 7))
      expect(markerIndex.getRange("c")).toBeUndefined()
      expect(markerIndex.getRange("d")).toEqual Range(Point(0, 0), Point(0, 0))
      expect(markerIndex.getRange("e")).toBeUndefined()
      expect(markerIndex.getRange("f")).toBeUndefined()
      expect(markerIndex.getRange("g")).toEqual Range(Point(0, 3), Point(0, 3))

  describe "::findContaining(start, end)", ->
    it "returns the markers whose ranges contain the given range", ->
      markerIndex.insert("a", Point(0, 2), Point(0, 5))
      markerIndex.insert("b", Point(0, 3), Point(0, 7))
      markerIndex.insert("c", Point(0, 4), Point(0, 4))
      markerIndex.insert("d", Point(0, 8), Point(0, 8))

      # range queries
      expect(markerIndex.findContaining(Point(0, 1), Point(0, 3))).toEqualSet []
      expect(markerIndex.findContaining(Point(0, 2), Point(0, 4))).toEqualSet ["a"]
      expect(markerIndex.findContaining(Point(0, 3), Point(0, 4))).toEqualSet ["a", "b"]
      expect(markerIndex.findContaining(Point(0, 4), Point(0, 7))).toEqualSet ["b"]
      expect(markerIndex.findContaining(Point(0, 4), Point(0, 8))).toEqualSet []

      # point queries
      expect(markerIndex.findContaining(Point(0, 2))).toEqualSet ["a"]
      expect(markerIndex.findContaining(Point(0, 3))).toEqualSet ["a", "b"]
      expect(markerIndex.findContaining(Point(0, 5))).toEqualSet ["a", "b"]
      expect(markerIndex.findContaining(Point(0, 7))).toEqualSet ["b"]
      expect(markerIndex.findContaining(Point(0, 4))).toEqualSet ["a", "b", "c"]
      expect(markerIndex.findContaining(Point(0, 8))).toEqualSet ["d"]

  describe "::findContainedIn(start, end)", ->
    it "returns the markers whose ranges are contained in the given range", ->
      markerIndex.insert("a", Point(0, 2), Point(0, 5))
      markerIndex.insert("b", Point(0, 3), Point(0, 7))
      markerIndex.insert("c", Point(0, 4), Point(0, 4))

      # range queries
      expect(markerIndex.findContainedIn(Point(0, 1), Point(0, 3))).toEqualSet []
      expect(markerIndex.findContainedIn(Point(0, 1), Point(0, 5))).toEqualSet ["a", "c"]
      expect(markerIndex.findContainedIn(Point(0, 2), Point(0, 5))).toEqualSet ["a", "c"]
      expect(markerIndex.findContainedIn(Point(0, 2), Point(0, 8))).toEqualSet ["a", "b", "c"]
      expect(markerIndex.findContainedIn(Point(0, 3), Point(0, 8))).toEqualSet ["b", "c"]
      expect(markerIndex.findContainedIn(Point(0, 5), Point(0, 8))).toEqualSet []

      # point queries
      expect(markerIndex.findContainedIn(Point(0, 4))).toEqualSet ["c"]
      expect(markerIndex.findContainedIn(Point(0, 5))).toEqualSet []

  describe "::findIntersecting(start, end)", ->
    it "returns the markers whose ranges intersect the given range", ->
      markerIndex.insert("a", Point(0, 2), Point(0, 5))
      markerIndex.insert("b", Point(0, 3), Point(0, 7))

      # range queries
      expect(markerIndex.findIntersecting(Point(0, 0), Point(0, 1))).toEqualSet []
      expect(markerIndex.findIntersecting(Point(0, 1), Point(0, 2))).toEqualSet ["a"]
      expect(markerIndex.findIntersecting(Point(0, 1), Point(0, 3))).toEqualSet ["a", "b"]
      expect(markerIndex.findIntersecting(Point(0, 3), Point(0, 4))).toEqualSet ["a", "b"]
      expect(markerIndex.findIntersecting(Point(0, 5), Point(0, 6))).toEqualSet ["a", "b"]
      expect(markerIndex.findIntersecting(Point(0, 6), Point(0, 8))).toEqualSet ["b"]
      expect(markerIndex.findIntersecting(Point(0, 8), Point(0, 9))).toEqualSet []

      # point queries
      expect(markerIndex.findIntersecting(Point(0, 2))).toEqualSet ["a"]
      expect(markerIndex.findIntersecting(Point(0, 3))).toEqualSet ["a", "b"]
      expect(markerIndex.findIntersecting(Point(0, 4))).toEqualSet ["a", "b"]
      expect(markerIndex.findIntersecting(Point(0, 5))).toEqualSet ["a", "b"]
      expect(markerIndex.findIntersecting(Point(0, 7))).toEqualSet ["b"]

  describe "::findStartingIn(start, end)", ->
    it "returns markers starting at the given point", ->
      markerIndex.insert("a", Point(0, 0), Point(0, 0))
      markerIndex.insert("b", Point(0, 2), Point(0, 5))
      markerIndex.insert("c", Point(0, 2), Point(0, 7))
      markerIndex.insert("d", Point(0, 4), Point(0, 8))

      # range queries
      expect(markerIndex.findStartingIn(Point(0, 0), Point(0, 0))).toEqualSet ["a"]
      expect(markerIndex.findStartingIn(Point(0, 0), Point(0, 1))).toEqualSet ["a"]
      expect(markerIndex.findStartingIn(Point(0, 1), Point(0, 2))).toEqualSet ["b", "c"]
      expect(markerIndex.findStartingIn(Point(0, 2), Point(0, 3))).toEqualSet ["b", "c"]
      expect(markerIndex.findStartingIn(Point(0, 2), Point(0, 4))).toEqualSet ["b", "c", "d"]
      expect(markerIndex.findStartingIn(Point(0, 4), Point(0, 5))).toEqualSet ["d"]
      expect(markerIndex.findStartingIn(Point(0, 3), Point(0, 5))).toEqualSet ["d"]
      expect(markerIndex.findStartingIn(Point(0, 6), Point(0, 8))).toEqualSet []

      # point queries
      expect(markerIndex.findStartingIn(Point(0, 1))).toEqualSet []
      expect(markerIndex.findStartingIn(Point(0, 2))).toEqualSet ["b", "c"]
      expect(markerIndex.findStartingIn(Point(0, 3))).toEqualSet []
      expect(markerIndex.findStartingIn(Point(0, 4))).toEqualSet ["d"]
      expect(markerIndex.findStartingIn(Point(0, 5))).toEqualSet []

  describe "::findEndingIn(start, end)", ->
    it "returns markers ending at the given point", ->
      markerIndex.insert("a", Point(0, 2), Point(0, 5))
      markerIndex.insert("b", Point(0, 3), Point(0, 7))
      markerIndex.insert("c", Point(0, 4), Point(0, 7))

      # range queries
      expect(markerIndex.findEndingIn(Point(0, 0), Point(0, 4))).toEqualSet []
      expect(markerIndex.findEndingIn(Point(0, 0), Point(0, 5))).toEqualSet ["a"]
      expect(markerIndex.findEndingIn(Point(0, 5), Point(0, 6))).toEqualSet ["a"]
      expect(markerIndex.findEndingIn(Point(0, 2), Point(0, 6))).toEqualSet ["a"]
      expect(markerIndex.findEndingIn(Point(0, 1), Point(0, 7))).toEqualSet ["a", "b", "c"]
      expect(markerIndex.findEndingIn(Point(0, 1), Point(0, 8))).toEqualSet ["a", "b", "c"]

      # point queries
      expect(markerIndex.findEndingIn(Point(0, 4))).toEqualSet []
      expect(markerIndex.findEndingIn(Point(0, 5))).toEqualSet ["a"]
      expect(markerIndex.findEndingIn(Point(0, 6))).toEqualSet []
      expect(markerIndex.findEndingIn(Point(0, 7))).toEqualSet ["b", "c"]
      expect(markerIndex.findEndingIn(Point(0, 8))).toEqualSet []

  describe "::splice(position, oldExtent, newExtent)", ->
    describe "when the change has a non-empty old extent and new extent", ->
      it "updates markers based on the change", ->
        markerIndex.insert("preceding", Point(0, 3), Point(0, 4))
        markerIndex.insert("ending-at-start", Point(0, 3), Point(0, 5))
        markerIndex.insert("overlapping-start", Point(0, 4), Point(0, 6))
        markerIndex.insert("starting-at-start", Point(0, 5), Point(0, 7))
        markerIndex.insert("within", Point(0, 6), Point(0, 7))
        markerIndex.insert("surrounding", Point(0, 4), Point(0, 9))
        markerIndex.insert("ending-at-end", Point(0, 6), Point(0, 8))
        markerIndex.insert("overlapping-end", Point(0, 6), Point(0, 9))
        markerIndex.insert("starting-at-end", Point(0, 8), Point(0, 10))
        markerIndex.insert("following", Point(0, 9), Point(0, 10))

        markerIndex.splice(Point(0, 5), Point(0, 3), Point(0, 4))

        # Markers that preceded the change do not move.
        expect(markerIndex.getRange("preceding")).toEqual Range(Point(0, 3), Point(0, 4))

        # Markers that ended at the start of the change do not move.
        expect(markerIndex.getRange("ending-at-start")).toEqual Range(Point(0, 3), Point(0, 5))

        # Markers that overlapped the start of the change maintain their start
        # position, and now end at the end of the change.
        expect(markerIndex.getRange("overlapping-start")).toEqual Range(Point(0, 4), Point(0, 9))

        # Markers that start at the start of the change maintain their start
        # position.
        expect(markerIndex.getRange("starting-at-start")).toEqual Range(Point(0, 5), Point(0, 9))

        # Markers that were within the change become points at the end of the
        # change.
        expect(markerIndex.getRange("within")).toEqual Range(Point(0, 9), Point(0, 9))

        # Markers that surrounded the change maintain their start position and
        # their logical end position.
        expect(markerIndex.getRange("surrounding")).toEqual Range(Point(0, 4), Point(0, 10))

        # Markers that end at the end of the change maintain their logical end
        # position.
        expect(markerIndex.getRange("ending-at-end")).toEqual Range(Point(0, 9), Point(0, 9))

        # Markers that overlapped the end of the change now start at the end of
        # the change, and maintain their logical end position.
        expect(markerIndex.getRange("overlapping-end")).toEqual Range(Point(0, 9), Point(0, 10))

        # Markers that start at the end of the change maintain their logical
        # start and end positions.
        expect(markerIndex.getRange("starting-at-end")).toEqual Range(Point(0, 9), Point(0, 11))

        # Markers that followed the change maintain their logical start and end
        # positions.
        expect(markerIndex.getRange("following")).toEqual Range(Point(0, 10), Point(0, 11))

    describe "when the change has an empty old extent", ->
      describe "when there is no marker boundary at the splice location", ->
        it "treats the change as being inside markers that it intersects", ->
          markerIndex.insert("surrounds-point", Point(0, 3), Point(0, 8))

          markerIndex.splice(Point(0, 5), Point(0, 0), Point(0, 4))

          expect(markerIndex.getRange("surrounds-point")).toEqual Range(Point(0, 3), Point(0, 12))

      describe "when a non-empty marker starts or ends at the splice position", ->
        it "treats the change as being inside markers that it intersects unless they are exclusive", ->
          markerIndex.insert("starts-at-point", Point(0, 5), Point(0, 8))
          markerIndex.insert("ends-at-point", Point(0, 3), Point(0, 5))

          markerIndex.insert("starts-at-point-exclusive", Point(0, 5), Point(0, 8))
          markerIndex.insert("ends-at-point-exclusive", Point(0, 3), Point(0, 5))
          markerIndex.setExclusive("starts-at-point-exclusive", true)
          markerIndex.setExclusive("ends-at-point-exclusive", true)

          expect(markerIndex.isExclusive("starts-at-point")).toBe false
          expect(markerIndex.isExclusive("starts-at-point-exclusive")).toBe true

          markerIndex.splice(Point(0, 5), Point(0, 0), Point(0, 4))

          expect(markerIndex.getRange("starts-at-point")).toEqual Range(Point(0, 5), Point(0, 12))
          expect(markerIndex.getRange("ends-at-point")).toEqual Range(Point(0, 3), Point(0, 9))
          expect(markerIndex.getRange("starts-at-point-exclusive")).toEqual Range(Point(0, 9), Point(0, 12))
          expect(markerIndex.getRange("ends-at-point-exclusive")).toEqual Range(Point(0, 3), Point(0, 5))

      describe "when there is an empty marker at the splice position", ->
        it "treats the change as being inside markers that it intersects", ->
          markerIndex.insert("starts-at-point", Point(0, 5), Point(0, 8))
          markerIndex.insert("ends-at-point", Point(0, 3), Point(0, 5))
          markerIndex.insert("at-point-inclusive", Point(0, 5), Point(0, 5))
          markerIndex.insert("at-point-exclusive", Point(0, 5), Point(0, 5))
          markerIndex.setExclusive("at-point-exclusive", true)

          markerIndex.splice(Point(0, 5), Point(0, 0), Point(0, 4))

          expect(markerIndex.getRange("starts-at-point")).toEqual Range(Point(0, 5), Point(0, 12))
          expect(markerIndex.getRange("ends-at-point")).toEqual Range(Point(0, 3), Point(0, 9))
          expect(markerIndex.getRange("at-point-inclusive")).toEqual Range(Point(0, 5), Point(0, 9))
          expect(markerIndex.getRange("at-point-exclusive")).toEqual Range(Point(0, 9), Point(0, 9))

    describe "when the change spans multiple rows", ->
      it "updates markers based on the change", ->
        markerIndex.insert("a", Point(0, 6), Point(0, 9))

        markerIndex.splice(Point(0, 1), Point(0, 0), Point(1, 3))
        expect(markerIndex.getRange("a")).toEqual Range(Point(1, 8), Point(1, 11))

        markerIndex.splice(Point(0, 1), Point(1, 3), Point(0, 0))
        expect(markerIndex.getRange("a")).toEqual Range(Point(0, 6), Point(0, 9))

        markerIndex.splice(Point(0, 5), Point(0, 3), Point(1, 3))
        expect(markerIndex.getRange("a")).toEqual Range(Point(1, 3), Point(1, 4))

  describe "::dump()", ->
    it "returns an object containing each marker's range and exclusivity", ->
      markerIndex.insert("a", Point(0, 2), Point(0, 5))
      markerIndex.insert("b", Point(0, 3), Point(0, 7))
      markerIndex.insert("c", Point(0, 4), Point(0, 4))
      markerIndex.insert("d", Point(0, 7), Point(0, 8))

      expect(markerIndex.dump()).toEqual {
        "a": Range(Point(0, 2), Point(0, 5))
        "b": Range(Point(0, 3), Point(0, 7))
        "c": Range(Point(0, 4), Point(0, 4))
        "d": Range(Point(0, 7), Point(0, 8))
      }

  describe "randomized mutations", ->
    [seed, random, markers, idCounter] = []

    it "maintains data structure invariants and returns correct query results", ->
      for i in [1..10]
        seed = Date.now() # paste the failing seed here to reproduce if there are failures
        random = new Random(seed)
        markers = []
        idCounter = 1
        markerIndex = new MarkerIndex

        for j in [1..50]
          # 60% insert, 20% splice, 20% delete

          if markers.length is 0 or random(10) > 4
            id = String(idCounter++)
            [start, end] = getRange()
            # console.log "#{j}: insert(#{id}, #{start}, #{end})"
            markerIndex.insert(id, start, end)
            markers.push({id, start, end})
          else if random(10) > 2
            [start, oldExtent, newExtent] = getSplice()
            # console.log "#{j}: splice(#{start}, #{oldExtent}, #{newExtent})"
            markerIndex.splice(start, oldExtent, newExtent)
            spliceMarkers(start, oldExtent, newExtent)
          else
            [{id}] = markers.splice(random(markers.length - 1), 1)
            # console.log "#{j}: delete(#{id})"
            markerIndex.delete(id)

          # console.log markerIndex.rootNode.toString()

          for {id, start, end} in markers
            expect(markerIndex.getStart(id)).toEqual start, "(Marker #{id} start; Seed: #{seed})"
            expect(markerIndex.getEnd(id)).toEqual end, "(Marker #{id} end; Seed: #{seed})"

          for k in [1..10]
            [queryStart, queryEnd] = getRange()
            # console.log "#{k}: findContaining(#{queryStart}, #{queryEnd})"
            expect(markerIndex.findContaining(queryStart, queryEnd)).toEqualSet(getExpectedContaining(queryStart, queryEnd), "(Seed: #{seed})")

          return if currentSpecFailed()

    getSplice = ->
      start = Point(random(100), random(100))
      oldExtent = Point(random(100 - start.row), random(100))
      newExtent = Point(random(100 - start.row), random(100))
      [start, oldExtent, newExtent]

    spliceMarkers = (spliceStart, oldExtent, newExtent) ->
      spliceOldEnd = spliceStart.traverse(oldExtent)
      spliceNewEnd = spliceStart.traverse(newExtent)

      shiftBySplice = (point) ->
        spliceNewEnd.traverse(point.traversalFrom(spliceOldEnd))

      for marker in markers
        if spliceStart.compare(marker.start) < 0

          # replacing text before the marker or inserting at the start of the marker
          if spliceOldEnd.compare(marker.start) <= 0
            marker.start = shiftBySplice(marker.start)
            marker.end = shiftBySplice(marker.end)

          # replacing text that overlaps the start of the marker
          else if spliceOldEnd.compare(marker.end) < 0
            marker.start = spliceNewEnd
            marker.end = shiftBySplice(marker.end)

          # replacing text surrounding the marker
          else
            marker.start = spliceNewEnd
            marker.end = spliceNewEnd

        else if spliceStart.isEqual(marker.start) and spliceStart.compare(marker.end) < 0

          # replacing text at the start of the marker, within the marker
          if spliceOldEnd.compare(marker.end) < 0
            marker.end = shiftBySplice(marker.end)

          # replacing text at the start of the marker, longer than the marker
          else
            marker.end = spliceNewEnd

        else if spliceStart.compare(marker.end) < 0

          # replacing text within the marker
          if spliceOldEnd.compare(marker.end) <= 0
            marker.end = shiftBySplice(marker.end)

          # replacing text that overlaps the end of the marker
          else if spliceOldEnd.compare(marker.end) > 0
            marker.end = spliceNewEnd

        else if spliceStart.compare(marker.end) is 0

          # inserting text at the end of the marker
          if spliceOldEnd.isEqual(marker.end)
            marker.end = spliceNewEnd

    getRange = ->
      start = Point(random(100), random(100))
      endRow = random.intBetween(start.row, 100)
      if endRow is start.row
        endColumn = random.intBetween(start.column, 100)
      else
        endColumn = random.intBetween(0, 100)
      end = Point(endRow, endColumn)
      [start, end]

    getExpectedContaining = (start, end) ->
      expected = []
      for marker in markers
        if marker.start.compare(start) <= 0 and end.compare(marker.end) <= 0
          expected.push(marker.id)
      expected
