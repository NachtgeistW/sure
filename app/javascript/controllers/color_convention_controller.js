import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  update(event) {
    document.documentElement.setAttribute(
      "data-color-convention",
      event.currentTarget.value,
    );
  }
}
