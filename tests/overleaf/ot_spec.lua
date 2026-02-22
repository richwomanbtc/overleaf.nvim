local ot = require('overleaf.ot')

describe('ot', function()
  describe('utf8_len', function()
    it('counts ASCII characters', function()
      assert.are.equal(5, ot.utf8_len('hello'))
    end)

    it('counts empty string', function()
      assert.are.equal(0, ot.utf8_len(''))
    end)

    it('counts 2-byte characters', function()
      -- café: c(1) a(1) f(1) é(2 bytes) = 4 chars
      assert.are.equal(4, ot.utf8_len('café'))
    end)

    it('counts 3-byte characters (CJK)', function()
      -- 日本語: 3 chars, each 3 bytes
      assert.are.equal(3, ot.utf8_len('日本語'))
    end)

    it('counts 4-byte characters (emoji)', function()
      assert.are.equal(1, ot.utf8_len('😀'))
    end)

    it('counts mixed ASCII and multibyte', function()
      -- "a日b" = 3 chars
      assert.are.equal(3, ot.utf8_len('a日b'))
    end)
  end)

  describe('byte_to_char', function()
    it('returns 0 for offset 0', function()
      assert.are.equal(0, ot.byte_to_char('hello', 0))
    end)

    it('handles ASCII correctly', function()
      assert.are.equal(3, ot.byte_to_char('hello', 3))
    end)

    it('converts byte offset in multibyte string', function()
      -- "café": c(1) a(2) f(3) é(4,5) -> byte 3 = char 3
      assert.are.equal(3, ot.byte_to_char('café', 3))
    end)

    it('converts byte offset past multibyte char', function()
      -- "café": é starts at byte 4, ends at byte 5 -> byte 5 = char 4
      assert.are.equal(4, ot.byte_to_char('café', 5))
    end)

    it('handles CJK characters', function()
      -- "日本語": 日(1-3) 本(4-6) 語(7-9)
      -- byte_offset=3 -> char 1, byte_offset=6 -> char 2
      assert.are.equal(1, ot.byte_to_char('日本語', 3))
      assert.are.equal(2, ot.byte_to_char('日本語', 6))
    end)
  end)

  describe('char_to_byte', function()
    it('returns 0 for offset 0', function()
      assert.are.equal(0, ot.char_to_byte('hello', 0))
    end)

    it('handles ASCII correctly', function()
      assert.are.equal(3, ot.char_to_byte('hello', 3))
    end)

    it('converts char offset in multibyte string', function()
      -- "café": char 3 (f) = byte 3
      assert.are.equal(3, ot.char_to_byte('café', 3))
    end)

    it('converts char offset past multibyte char', function()
      -- "café": char 4 (end) = byte 5
      assert.are.equal(5, ot.char_to_byte('café', 4))
    end)

    it('handles CJK characters', function()
      -- "日本語": char 1 = byte 3, char 2 = byte 6
      assert.are.equal(3, ot.char_to_byte('日本語', 1))
      assert.are.equal(6, ot.char_to_byte('日本語', 2))
    end)

    it('roundtrips with byte_to_char', function()
      local s = 'hello日本語world'
      for i = 0, ot.utf8_len(s) do
        local b = ot.char_to_byte(s, i)
        local c = ot.byte_to_char(s, b)
        assert.are.equal(i, c, 'roundtrip failed at char ' .. i)
      end
    end)
  end)

  describe('apply', function()
    it('inserts text at beginning', function()
      local result = ot.apply('world', { { p = 0, i = 'hello ' } })
      assert.are.equal('hello world', result)
    end)

    it('inserts text at end', function()
      local result = ot.apply('hello', { { p = 5, i = ' world' } })
      assert.are.equal('hello world', result)
    end)

    it('inserts text in middle', function()
      local result = ot.apply('hllo', { { p = 1, i = 'e' } })
      assert.are.equal('hello', result)
    end)

    it('deletes text', function()
      local result = ot.apply('hello world', { { p = 5, d = ' world' } })
      assert.are.equal('hello', result)
    end)

    it('deletes from beginning', function()
      local result = ot.apply('hello world', { { p = 0, d = 'hello ' } })
      assert.are.equal('world', result)
    end)

    it('applies multiple operations sequentially', function()
      local result = ot.apply('abc', {
        { p = 3, i = 'd' }, -- "abcd"
        { p = 0, i = 'x' }, -- "xabcd"
      })
      assert.are.equal('xabcd', result)
    end)

    it('handles multibyte insert', function()
      local result = ot.apply('ab', { { p = 1, i = '日' } })
      assert.are.equal('a日b', result)
    end)

    it('handles multibyte delete', function()
      local result = ot.apply('a日b', { { p = 1, d = '日' } })
      assert.are.equal('ab', result)
    end)

    it('handles empty ops list', function()
      local result = ot.apply('hello', {})
      assert.are.equal('hello', result)
    end)
  end)

  describe('transform_component', function()
    describe('insert vs insert', function()
      it('left side wins at same position', function()
        local result = ot.transform_component({ p = 5, i = 'a' }, { p = 5, i = 'b' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(5, result[1].p)
        assert.are.equal('a', result[1].i)
      end)

      it('right side loses at same position', function()
        local result = ot.transform_component({ p = 5, i = 'a' }, { p = 5, i = 'b' }, 'right')
        assert.are.equal(1, #result)
        assert.are.equal(6, result[1].p)
        assert.are.equal('a', result[1].i)
      end)

      it('shifts insert after other insert', function()
        local result = ot.transform_component({ p = 10, i = 'x' }, { p = 5, i = 'abc' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(13, result[1].p)
      end)

      it('no shift for insert before other insert', function()
        local result = ot.transform_component({ p = 2, i = 'x' }, { p = 5, i = 'abc' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(2, result[1].p)
      end)
    end)

    describe('insert vs delete', function()
      it('no shift when insert is before delete', function()
        local result = ot.transform_component({ p = 2, i = 'x' }, { p = 5, d = 'abc' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(2, result[1].p)
      end)

      it('shifts insert back when after delete', function()
        local result = ot.transform_component({ p = 10, i = 'x' }, { p = 5, d = 'abc' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(7, result[1].p)
      end)

      it('moves insert to delete start when inside deleted region', function()
        local result = ot.transform_component({ p = 6, i = 'x' }, { p = 5, d = 'abc' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(5, result[1].p)
      end)
    end)

    describe('delete vs insert', function()
      it('no shift when delete is after insert', function()
        local result = ot.transform_component({ p = 10, d = 'abc' }, { p = 5, i = 'xy' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(12, result[1].p)
      end)

      it('splits delete when insert is in the middle', function()
        local result = ot.transform_component({ p = 5, d = 'abcdef' }, { p = 7, i = 'xy' }, 'left')
        assert.are.equal(2, #result)
        assert.are.equal(5, result[1].p)
        assert.are.equal('ab', result[1].d)
        assert.are.equal(9, result[2].p)
        assert.are.equal('cdef', result[2].d)
      end)
    end)

    describe('delete vs delete', function()
      it('no overlap, c2 before c1', function()
        local result = ot.transform_component({ p = 10, d = 'abc' }, { p = 5, d = 'xy' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(8, result[1].p)
        assert.are.equal('abc', result[1].d)
      end)

      it('c2 completely contains c1', function()
        local result = ot.transform_component({ p = 6, d = 'bc' }, { p = 5, d = 'abcde' }, 'left')
        assert.are.equal(0, #result)
      end)

      it('c2 overlaps start of c1', function()
        local result = ot.transform_component({ p = 5, d = 'abcde' }, { p = 3, d = 'xxab' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(3, result[1].p)
        assert.are.equal('cde', result[1].d)
      end)

      it('c2 is inside c1', function()
        local result = ot.transform_component({ p = 5, d = 'abcde' }, { p = 7, d = 'cd' }, 'left')
        assert.are.equal(1, #result)
        assert.are.equal(5, result[1].p)
        assert.are.equal('abe', result[1].d)
      end)
    end)
  end)

  describe('transform_ops', function()
    it('transforms a list of ops against another list', function()
      local ops1 = { { p = 5, i = 'x' } }
      local ops2 = { { p = 3, i = 'abc' } }
      local result = ot.transform_ops(ops1, ops2, 'left')
      assert.are.equal(1, #result)
      assert.are.equal(8, result[1].p) -- shifted by 3
    end)
  end)

  describe('compose', function()
    it('concatenates two op lists', function()
      local ops1 = { { p = 0, i = 'a' } }
      local ops2 = { { p = 1, i = 'b' } }
      local result = ot.compose(ops1, ops2)
      assert.are.equal(2, #result)
      assert.are.equal('a', result[1].i)
      assert.are.equal('b', result[2].i)
    end)
  end)

  describe('byte_offset_to_pos', function()
    it('returns (0,0) for offset 0', function()
      local row, col = ot.byte_offset_to_pos('hello\nworld', 0)
      assert.are.equal(0, row)
      assert.are.equal(0, col)
    end)

    it('returns correct position on second line', function()
      -- "hello\nworld" -> offset 6 = 'w' on line 1, col 0
      local row, col = ot.byte_offset_to_pos('hello\nworld', 6)
      assert.are.equal(1, row)
      assert.are.equal(0, col)
    end)

    it('roundtrips with pos_to_byte_offset', function()
      local content = 'line one\nline two\nline three'
      for offset = 0, #content - 1 do
        local row, col = ot.byte_offset_to_pos(content, offset)
        local back = ot.pos_to_byte_offset(content, row, col)
        assert.are.equal(offset, back, 'roundtrip failed at offset ' .. offset)
      end
    end)
  end)
end)
