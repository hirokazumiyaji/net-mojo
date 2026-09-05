from std.testing import assert_equal


def _assert_bytes_equal[
    left_origin: MutOrigin, right_origin: ImmOrigin
](
    left: Span[mut=True, Byte, left_origin], right: Span[Byte, right_origin]
) raises:
    assert_equal(len(left), len(right))
    for i in range(len(left)):
        assert_equal(left[i], right[i])
