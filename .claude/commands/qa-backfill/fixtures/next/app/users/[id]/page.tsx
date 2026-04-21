export default function UserPage({ params }: { params: { id: string } }) {
  return <main>user {params.id}</main>;
}
