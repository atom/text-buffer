Point = require "../src/point"
RegionMap = require "../src/region-map"

describe "RegionMap", ->
  regionMap = null

  beforeEach ->
    regionMap = new RegionMap

  describe "iterator", ->
    it "terminates after traversing to infinity when the region map is empty", ->
      iterator = regionMap[Symbol.iterator]()
      expect(iterator.getPosition()).toEqual(Point.zero())

      expect(iterator.next()).toEqual(value: null, done: false)
      expect(iterator.getPosition()).toEqual(Point.infinity())
      expect(iterator.getSourcePosition()).toEqual(Point.infinity())

      expect(iterator.next()).toEqual(value: null, done: true)
      expect(iterator.getPosition()).toEqual(Point.infinity())
      expect(iterator.getSourcePosition()).toEqual(Point.infinity())

    describe "splicing with a positive delta", ->
      iterator = null

      beforeEach ->
        iterator = regionMap[Symbol.iterator]()
        iterator.seek(Point(0, 2))
        iterator.splice(Point(0, 3), "abcde")

      it "inserts new content into the map", ->
        expect(iterator.getPosition()).toEqual(Point(0, 5))
        iterator.seek(Point.zero())

        expect(iterator.next()).toEqual(value: null, done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 2))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 2))

        expect(iterator.next()).toEqual(value: "abcde", done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 7))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 5))

        expect(iterator.next()).toEqual(value: null, done: false)
        expect(iterator.getPosition()).toEqual(Point.infinity())
        expect(iterator.getSourcePosition()).toEqual(Point.infinity())

        iterator.seek(Point(0, 6))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 5))

        expect(iterator.next()).toEqual(value: "e", done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 7))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 5))

      describe "expanding an existing positive-delta splice", ->
        beforeEach ->
          iterator.seek(Point(0, 4))
          iterator.splice(Point(0, 2), "fghi")

        it "stretches the existing splice region", ->
          expect(iterator.getPosition()).toEqual(Point(0, 6))
          iterator.seek(Point.zero())

          expect(iterator.next()).toEqual(value: null, done: false)
          expect(iterator.getPosition()).toEqual(Point(0, 2))
          expect(iterator.getSourcePosition()).toEqual(Point(0, 2))

          expect(iterator.next()).toEqual(value: "abfghie", done: false)
          expect(iterator.getPosition()).toEqual(Point(0, 9))
          expect(iterator.getSourcePosition()).toEqual(Point(0, 5))

          expect(iterator.next()).toEqual(value: null, done: false)
          expect(iterator.getPosition()).toEqual(Point.infinity())
          expect(iterator.getSourcePosition()).toEqual(Point.infinity())

    describe "splicing with a negative delta", ->
      iterator = null

      beforeEach ->
        iterator = regionMap[Symbol.iterator]()
        iterator.seek(Point(0, 2))
        iterator.splice(Point(0, 5), "abc")

      it "inserts new content into the map", ->
        iterator.seek(Point(0, 0))

        expect(iterator.next()).toEqual(value: null, done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 2))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 2))

        expect(iterator.next()).toEqual(value: "abc", done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 5))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        expect(iterator.next()).toEqual(value: null, done: false)
        expect(iterator.getPosition()).toEqual(Point.infinity())
        expect(iterator.getSourcePosition()).toEqual(Point.infinity())

        iterator.seek(Point(0, 5))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))

        iterator.seek(Point(0, 3))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 3))

        expect(iterator.next()).toEqual(value: "bc", done: false)
        expect(iterator.getPosition()).toEqual(Point(0, 5))
        expect(iterator.getSourcePosition()).toEqual(Point(0, 7))
