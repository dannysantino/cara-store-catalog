import { Link } from 'react-router'

const Navbar = () => {
    return (
        <nav className="navbar navbar-expand-lg bg-dark-subtle py-3">
            <div className="container">
                <Link className="navbar-brand mb-0 h1" to="/">Cara Store Catalog</Link>
                <button
                    className="navbar-toggler"
                    type="button"
                    data-bs-toggle="collapse"
                    data-bs-target="#navbarNavAltMarkup"
                    aria-controls="navbarNavAltMarkup"
                    aria-expanded="false"
                    aria-label="Toggle navigation">
                    <span className="navbar-toggler-icon"></span>
                </button>
                {/* <div className="collapse navbar-collapse" id="navbarNavAltMarkup">
                    <div className="navbar-nav ms-auto">
                        <Link to="/add" className="nav-link">Add Products</Link>
                    </div>
                </div> */}
            </div>
        </nav>
    )
}

export default Navbar