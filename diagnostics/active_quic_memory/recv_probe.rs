#[cfg(test)]
impl RecvBuf {
    pub(crate) fn diagnostic_slots(&self) -> (usize, usize) {
        let positive = self.data.values().filter(|range| !range.is_empty()).count();
        (positive, self.data.len() - positive)
    }

    pub(crate) fn diagnostic_retained(&self) -> (usize, usize, usize) {
        let mut backing = std::collections::HashMap::new();
        for range in self.data.values() {
            let bytes = range.diagnostic_backing();
            backing.insert(bytes.as_ptr(), bytes.len());
        }
        (
            self.data.len(),
            self.data.values().map(|range| range.len()).sum(),
            backing.values().sum(),
        )
    }
}
