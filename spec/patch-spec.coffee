Point = require "../src/point"
Patch = require "../src/patch"
{currentSpecFailed} = require "./spec-helper"

describe "Patch", ->
  patch = null

  beforeEach ->
    patch = new Patch

  describe "iterator", ->
    iterator = null

    expectHunks = (iterator, hunks) ->
      for [inputPosition, outputPosition, value], i in hunks
        expect(iterator.next()).toEqual {value, done: false}, "value for hunk #{i}"
        expect(iterator.getInputPosition()).toEqual inputPosition, "input position for hunk #{i}"
        expect(iterator.getOutputPosition()).toEqual outputPosition, "output position for hunk #{i}"
        return if currentSpecFailed()

      expect(iterator.next()).toEqual {value: null, done: true}
      expect(iterator.getOutputPosition()).toEqual Point.infinity()
      expect(iterator.getInputPosition()).toEqual Point.infinity()

    logTree = ->
      console.log ''
      console.log patch.rootNode.toString()
      console.log ''

    describe "::seek(position)", ->
      it "moves the iterator to the given position in the patch", ->
        patch.splice(Point(0, 5), Point(0, 2), Point(0, 4), "abcd")
        patch.splice(Point(0, 12), Point(0, 4), Point(0, 3), "efg")
        patch.splice(Point(0, 16), Point(0, 3), Point(0, 2), "hi")

        iterator = patch.buildIterator()

        iterator.seek(Point(0, 3))
        expect(iterator.getInputPosition()).toEqual Point(0, 3)
        expect(iterator.getOutputPosition()).toEqual Point(0, 3)
        expectHunks iterator, [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 7), Point(0, 9), "abcd"]
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.infinity(), Point.infinity(), null]
        ]

        iterator.seek(Point(0, 8))
        expect(iterator.getInputPosition()).toEqual Point(0, 7)
        expect(iterator.getOutputPosition()).toEqual Point(0, 8)
        expectHunks iterator, [
          [Point(0, 7), Point(0, 9), "d"]
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.infinity(), Point.infinity(), null]
        ]

        iterator.seek(Point(0, 13))
        expect(iterator.getInputPosition()).toEqual Point(0, 11)
        expect(iterator.getOutputPosition()).toEqual Point(0, 13)
        expectHunks iterator, [
          [Point(0, 14), Point(0, 15), "fg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.infinity(), Point.infinity(), null]
        ]

    describe "::seekToInputPosition(position)", ->
      it "moves the iterator to the given input position in the patch", ->
        patch.splice(Point(0, 5), Point(0, 2), Point(0, 4), "abcd")
        patch.splice(Point(0, 12), Point(0, 4), Point(0, 3), "efg")
        patch.splice(Point(0, 16), Point(0, 3), Point(0, 2), "hi")

        iterator = patch.buildIterator()

        iterator.seekToInputPosition(Point(0, 3))
        expect(iterator.getInputPosition()).toEqual(Point(0, 3))
        expect(iterator.getOutputPosition()).toEqual(Point(0, 3))
        expectHunks iterator, [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 7), Point(0, 9), "abcd"]
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.infinity(), Point.infinity(), null]
        ]

        iterator.seekToInputPosition(Point(0, 7))
        expect(iterator.getInputPosition()).toEqual(Point(0, 7))
        expect(iterator.getOutputPosition()).toEqual(Point(0, 9))
        expectHunks iterator, [
          [Point(0, 10), Point(0, 12), null]
          [Point(0, 14), Point(0, 15), "efg"]
          [Point(0, 15), Point(0, 16), null]
          [Point(0, 18), Point(0, 18), "hi"]
          [Point.infinity(), Point.infinity(), null]
        ]

      describe "boundaries", ->
        beforeEach ->
          iterator = patch.buildIterator()

          iterator.seekToInputPosition(Point(0, 5))
          iterator.insertBoundary()
          iterator.splice(Point(0, 3), Point(0, 4), "abcd")

          iterator.seekToInputPosition(Point(0, 10))
          iterator.splice(Point(0, 2), Point(0, 3), "efg")

          iterator.seekToInputPosition(Point(0, 15))
          iterator.insertBoundary()

          iterator.seekToInputPosition(Point(0, 17))
          iterator.splice(Point(0, 4), Point(0, 2), "hi")

        it "can seek to the boundary to the left of the given position", ->
          iterator.seekToLeftBoundaryForInputPosition(Point(0, 9))
          expect(iterator.getInputPosition()).toEqual Point(0, 5)
          expect(iterator.getOutputPosition()).toEqual Point(0, 5)

          iterator.seekToLeftBoundaryForInputPosition(Point(0, 13))
          expect(iterator.getInputPosition()).toEqual Point(0, 5)
          expect(iterator.getOutputPosition()).toEqual Point(0, 5)

          iterator.seekToLeftBoundaryForInputPosition(Point(0, 5))
          expect(iterator.getInputPosition()).toEqual Point(0, 5)
          expect(iterator.getOutputPosition()).toEqual Point(0, 5)

          iterator.seekToLeftBoundaryForInputPosition(Point(0, 4))
          expect(iterator.getInputPosition()).toEqual Point(0, 0)
          expect(iterator.getOutputPosition()).toEqual Point(0, 0)

          iterator.seekToLeftBoundaryForInputPosition(Point(0, 25))
          expect(iterator.getInputPosition()).toEqual Point(0, 15)
          expect(iterator.getOutputPosition()).toEqual Point(0, 17)

    describe "::splice(oldOutputExtent, newOutputExtent, content)", ->
      it "can insert a single change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectHunks iterator, [
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can insert two disjoint changes", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 12)).splice(Point(0, 4), Point(0, 3), "efg")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point(0, 12), Point(0, 13), null]
          [Point(0, 16), Point(0, 16), "efg"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectHunks iterator, [
          [Point(0, 12), Point(0, 13), null]
          [Point(0, 16), Point(0, 16), "efg"]
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can insert three disjoint changes", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 11)).splice(Point(0, 4), Point(0, 3), "efg")
        iterator.seek(Point(0, 15)).splice(Point(0, 3), Point(0, 2), "hi")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 9), "abcd"]
          [Point(0, 11), Point(0, 12), null]
          [Point(0, 15), Point(0, 15), "efg"]
          [Point(0, 16), Point(0, 16), null]
          [Point(0, 19), Point(0, 18), "hi"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 9)
        expectHunks iterator, [
          [Point(0, 11), Point(0, 12), null]
          [Point(0, 15), Point(0, 15), "efg"]
          [Point(0, 16), Point(0, 16), null]
          [Point(0, 19), Point(0, 18), "hi"]
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can perform a single deletion", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 8), Point(0, 5), ""]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 8)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can delete the start of an existing change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 8), Point(0, 5), "abcde")
        iterator.seek(Point(0, 3)).splice(Point(0, 6), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 13), Point(0, 4), "e"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 9)
        expect(iterator.getOutputPosition()).toEqual Point(0, 3)
        expectHunks iterator, [
          [Point(0, 13), Point(0, 4), "e"]
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can insert a change within a change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 3)).splice(Point(0, 5), Point(0, 8), "abcdefgh")
        iterator.seek(Point(0, 4)).splice(Point(0, 2), Point(0, 3), "ijk")

        expectHunks patch.buildIterator(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 8), Point(0, 12), "aijkdefgh"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 6)
        expect(iterator.getOutputPosition()).toEqual Point(0, 7)
        expectHunks iterator, [
          [Point(0, 8), Point(0, 12), "defgh"]
          [Point.infinity(), Point.infinity(), null]
        ]

        iterator.seek(Point(0, 4)).splice(Point(0, 3), Point(0, 1), "l")

        expectHunks patch.buildIterator(), [
          [Point(0, 3), Point(0, 3), null]
          [Point(0, 8), Point(0, 10), "aldefgh"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 7)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point(0, 8), Point(0, 10), "defgh"]
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can insert a change that overlaps the end of an existing change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")
        iterator.seek(Point(0, 8)).splice(Point(0, 4), Point(0, 5), "efghi")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 11), Point(0, 13), "abcefghi"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 11)
        expect(iterator.getOutputPosition()).toEqual Point(0, 13)
        expectHunks iterator, [
          [Point.infinity(), Point.infinity(), null]
        ]

        iterator.seek(Point(0, 9)).splice(Point(0, 6), Point(0, 3), "jkl")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 13), Point(0, 12), "abcejkl"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 13)
        expect(iterator.getOutputPosition()).toEqual Point(0, 12)
        expectHunks iterator, [
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can insert a change that overlaps the start of an existing change", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 8)).splice(Point(0, 4), Point(0, 5), "abcde")

        iterator.seek(Point(0, 5)).splice(Point(0, 5), Point(0, 3), "fgh")
        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 12), Point(0, 11), "fghcde"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 10)
        expect(iterator.getOutputPosition()).toEqual Point(0, 8)
        expectHunks iterator, [
          [Point(0, 12), Point(0, 11), "cde"]
          [Point.infinity(), Point.infinity(), null]
        ]

      it "can insert a change that joins two existing changes", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 4), "abcd")
        iterator.seek(Point(0, 12)).splice(Point(0, 3), Point(0, 4), "efgh")
        iterator.seek(Point(0, 7)).splice(Point(0, 7), Point(0, 4), "ijkl")

        expectHunks patch.buildIterator(), [
          [Point(0, 5), Point(0, 5), null]
          [Point(0, 14), Point(0, 13), "abijklgh"]
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 13)
        expect(iterator.getOutputPosition()).toEqual Point(0, 11)
        expectHunks iterator, [
          [Point(0, 14), Point(0, 13), "gh"]
          [Point.infinity(), Point.infinity(), null]
        ]

      it "deletes hunks for changes that are reverted", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 0), Point(0, 3), "abc")
        iterator.seek(Point(0, 5)).splice(Point(0, 3), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point.infinity(), Point.infinity(), null]
        ]

        iterator.seek(Point(0, 0)).splice(Point(0, 0), Point(0, 3), "abc")
        iterator.seek(Point(0, 0)).splice(Point(0, 3), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point.infinity(), Point.infinity(), null]
        ]

      it "does nothing if both ranges are empty", ->
        iterator = patch.buildIterator()
        iterator.seek(Point(0, 5)).splice(Point(0, 0), Point(0, 0), "")

        expectHunks patch.buildIterator(), [
          [Point.infinity(), Point.infinity(), null]
        ]

        expect(iterator.getInputPosition()).toEqual Point(0, 5)
        expect(iterator.getOutputPosition()).toEqual Point(0, 5)
        expectHunks iterator, [
          [Point.infinity(), Point.infinity(), null]
        ]
