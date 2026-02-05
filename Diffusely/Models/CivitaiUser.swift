struct CivitaiUser: Codable, Hashable {
    let id: Int
    let username: String?
    let image: String?

    init(id: Int, username: String?, image: String?) {
        self.id = id
        self.username = username
        self.image = image
    }
}
