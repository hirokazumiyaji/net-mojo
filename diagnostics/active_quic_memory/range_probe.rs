#[cfg(test)]
impl<F: BufFactory> RangeBuf<F> {
    pub(crate) fn diagnostic_backing(&self) -> &[u8] {
        self.data.as_ref()
    }
}
