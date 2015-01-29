Point = require '../src/point'

describe "Point", ->
  describe "::negate()", ->
    it "should negate the row and column", ->
      expect(new Point( 0,  0).negate().toString()).toBe "(0, 0)"
      expect(new Point( 1,  2).negate().toString()).toBe "(-1, -2)"
      expect(new Point(-1, -2).negate().toString()).toBe "(1, 2)"
      expect(new Point(-1,  2).negate().toString()).toBe "(1, -2)"
