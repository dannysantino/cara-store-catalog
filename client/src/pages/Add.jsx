import axios from 'axios';
import { useState } from 'react'
import { useNavigate } from 'react-router'

import { API_URL } from '../config'

const Add = () => {
    const [product, setProduct] = useState({});
    const navigate = useNavigate();

    const handleInput = e => {
        setProduct(prevState => ({
            ...prevState,
            [e.target.name]: e.target.value
        }));
    }

    const handleSubmit = async e => {
        e.preventDefault();
        try {
            await axios.post(`${API_URL}/products`, product);
            navigate("/");
        } catch (err) {
            console.error(err);
        }
    }

    return (
        <>
            <section className="page-header">
                <div className="container mt-5">
                    <div className="row">
                        <div className="col text-center">
                            <h3>Add a new product</h3>
                            <p>Enter product details below</p>
                        </div>
                    </div>
                </div>
            </section>

            <section id="add-product">
                <div className="container">
                    <div className="row justify-content-center mt-3">
                        <div className="col-md-5">
                            <div className="card shadow">
                                <div className="card-body">
                                    <form className="row g-3" onSubmit={handleSubmit}>
                                        <div className="col-12">
                                            <label htmlFor="name" className="form-label">Name</label>
                                            <input
                                                type="text"
                                                className="form-control"
                                                id="name"
                                                name="name"
                                                onChange={handleInput}
                                                required
                                            />
                                        </div>
                                        <div className="col-12">
                                            <label htmlFor="description" className="form-label">Description</label>
                                            <textarea
                                                className="form-control"
                                                id="description" rows={3}
                                                name="description"
                                                onChange={handleInput}
                                                required
                                            />
                                        </div>
                                        <div className="col-md-4">
                                            <label htmlFor="price" className="form-label">Price</label>
                                            <input
                                                type="number"
                                                className="form-control"
                                                id="price"
                                                name="price"
                                                onChange={handleInput}
                                                required
                                            />
                                        </div>
                                        <div className="col-md-8">
                                            <label htmlFor="img" className="form-label">Image URL</label>
                                            <input
                                                type="text"
                                                className="form-control"
                                                id="img"
                                                name="img"
                                                onChange={handleInput}
                                                required
                                            />
                                        </div>
                                        <div className="col text-center pt-3">
                                            <button className="btn btn-primary px-5">Add Product</button>
                                        </div>
                                    </form>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </section>
        </>
    )
}

export default Add