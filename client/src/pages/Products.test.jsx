import "@testing-library/jest-dom/vitest"
import { fireEvent, screen, waitFor } from "@testing-library/react"
import { expect, it, vi } from "vitest"
import axios from "axios"

import Products from "./Products"
import { renderWithRouter } from "../test-utils.jsx"
import { act } from "react"

vi.mock("axios");

describe("Products Page", () => {
    beforeEach(() => {
        axios.get.mockReset();
        axios.delete.mockReset();
    });

    afterEach(() => {
        vi.clearAllMocks();
    });

    it("renders the main heading", () => {
        renderWithRouter(<Products />);
        expect(screen.getByText("Products")).toBeInTheDocument();
        expect(screen.getByText("Add Product")).toBeInTheDocument();
        expect(screen.getByText("Check out our collection of products")).toBeInTheDocument();
    });

    it("renders loading message when no products are available", async () => {
        axios.get.mockResolvedValueOnce({ data: [] });

        await act(async () => {
            renderWithRouter(<Products />);
        });

        expect(screen.getByRole("heading", { name: /No products available at this time. Please check back later!/i })).toBeInTheDocument();
    });

    it("displays products when API call is successful", async () => {
        const mockProducts = [
            { id: 1, name: "Product 1", price: 237, description: "Test product 1", img: "https://imgurl.img1.jpg" },
            { id: 2, name: "Product 2", price: 189, description: "Test product 2", img: "https://imgurl.img2.jpg" }
        ];

        axios.get.mockResolvedValueOnce({ data: mockProducts });

        renderWithRouter(<Products />);

        await waitFor(() => {
            expect(screen.getByRole("heading", { name: /Product 1/i })).toBeInTheDocument();
            expect(screen.getByRole("heading", { name: /Product 2/i })).toBeInTheDocument();
        });
    });

    // it("deletes a product when the delete button is clicked", async () => {
    //     const mockProduct = [
    //         { id: 1, name: "Product 1", price: 237, description: "Test product 1", img: "https://imgurl.img1.jpg" }
    //     ];

    //     axios.get.mockResolvedValueOnce({ data: mockProduct });
    //     axios.delete.mockResolvedValueOnce({});

    //     renderWithRouter(<Products />);

    //     await waitFor(() => {
    //         expect(screen.getByRole("heading", { name: /Product 1/i })).toBeInTheDocument();
    //     });

    //     const deleteButton = screen.getByRole("link", { name: /Delete/i });

    //     fireEvent.click(deleteButton);

    //     expect(axios.delete).toHaveBeenCalledWith(`${import.meta.env.VITE_API_URL}/products/1`);
    // });

    // it("throws error when fetching products fails", async () => {
    //     axios.get.mockRejectedValueOnce(new Error("Network Error"));

    //     renderWithRouter(<Products />);

    //     await waitFor(() => {
    //         expect(screen.getByText(/No products available at this time/i)).toBeInTheDocument();
    //     });
    // });
});